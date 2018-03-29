//
//  TPTools.swift
//  tinypng
//
//  Created by kyle on 16/6/30.
//  Copyright © 2016年 kyleduo. All rights reserved.
//

import Foundation
import Alamofire
import SwiftyJSON

protocol TPClientCallback {
	func taskStatusChanged(task: TPTaskInfo)
}

class TPClient {
	let MAX_TASKS: Int = 5
	let BASE_URL = "https://api.tinify.com/shrink"
	
	static let sharedClient = TPClient()
    static var sApiKeys = [String]()
    static var sApiKey  = "" {
        didSet {
            sApiKeys = sApiKey.components(separatedBy: ",")
        }
    }
	static var sOutputPath = "" {
		didSet {
			IOHeler.sOutputPath = sOutputPath
		}
	}
	
	var callback:TPClientCallback!
	
	fileprivate init() {}
	
	let queue = TPQueue()
	let lock: NSLock = NSLock()
	var runningTasks = 0
	var finishTasksCount = 0
    var taskIndex = 0
    
	
	func add(_ tasks: [TPTaskInfo]) {
		TPStore.sharedStore.add(tasks);
		for task in tasks {
			queue.enqueue(task)
		}
	}
	
	func checkExecution() {
		lock.lock()
		while runningTasks < MAX_TASKS {
			let task = queue.dequeue()
			if let t = task {
				self.updateStatus(t, newStatus: .prepare)
				runningTasks += 1
				debugPrint("prepare to upload: " + t.fileName + " tasks: " + String(self.runningTasks))
				if !executeTask(t) {
					runningTasks -= 1
				}
			} else {
				break;
			}
		}
		lock.unlock()
	}
	
	func executeTask(_ task: TPTaskInfo) -> Bool {
		var imageData: Data!
		do {
			let fileHandler = try FileHandle(forReadingFrom:task.originFile as URL)
			imageData = fileHandler.readDataToEndOfFile()
			
            var auth = ""
            if TPClient.sApiKeys.count != 0 {
                let key = TPClient.sApiKeys[0]
                auth = "api:\(key)"
            }
            
			let authData = auth.data(using: String.Encoding.utf8)?.base64EncodedString(options: NSData.Base64EncodingOptions.lineLength64Characters)
			let authorizationHeader = "Basic " + authData!
			
			self.updateStatus(task, newStatus: .uploading)
			debugPrint("uploading: " + task.fileName)
			
			let headers: HTTPHeaders = [
				"Authorization": authorizationHeader,
				"Accept": "application/json"
			]
			Alamofire.upload(imageData, to: BASE_URL, method: .post, headers: headers)
				.uploadProgress(closure: { (progress) in
					if progress.fractionCompleted == 1 {
						self.updateStatus(task, newStatus: .processing)
						debugPrint("processing: " + task.fileName)
					} else {
						self.updateStatus(task, newStatus: .uploading, progress: progress)
					}
				})
				.responseJSON(completionHandler: { (response) in
					if let jsonstr = response.result.value {
						let json = JSON(jsonstr)
						if json != JSON.null {
							if let error = json["error"].string {
								debugPrint("error: " + task.fileName + error)
                                
                                //这里想处理monthly limit
                                if ((json["message"].string?.rangeOfCharacter(from: CharacterSet.init(charactersIn: "limit"))) != nil) {
                                    
                                    let rs = auth.substring(from: auth.index(auth.startIndex, offsetBy: 4));
                                    
                                    if auth.count > 0 {
                                        
                                        let index = TPClient.sApiKeys.index(of: rs)
                                        if index != nil {
                                            TPClient.sApiKeys.remove(at: index!)
                                        }
                                    }
                                    
                                    if TPClient.sApiKeys.count > 0 {
                                        self.credentialsError(task, errorMessage: "api key(\(rs) invalid")
                                        
                                        self.checkExecution()
                                    }
                                    else
                                    {
                                        self.markError(task, errorMessage: json["message"].string)
                                    }
                                }
                                else
                                {
                                    self.markError(task, errorMessage: json["message"].string)
                                }
                                
								return
							}
							let output = json["output"]
							if output != JSON.null {
								let resultUrl = output["url"]
								task.resultUrl = String(describing: resultUrl)
								task.resultSize = output["size"].doubleValue
								task.compressRate = task.resultSize / task.originSize
								self.onUploadFinish(task)
							} else {
								self.markError(task, errorMessage: "response data error")
							}
						} else {
							self.markError(task, errorMessage: "response format error")
						}
					} else {
						self.markError(task, errorMessage: response.result.description)
					}
				})
			return true
		} catch {
			self.markError(task, errorMessage: "execute error")
			return false
		}
	}
	
	fileprivate func onUploadFinish(_ task: TPTaskInfo) {
		debugPrint("downloading: " + task.fileName)
		self.updateStatus(task, newStatus: .downloading)
		if TPConfig.shouldReplace() {
			task.outputFile = task.originFile;
		} else {
			let folder = IOHeler.getOutputPath()
			task.outputFile = folder.appendingPathComponent(task.fileName)
		}
		downloadCompressImage(task)
	}
	
	fileprivate func downloadCompressImage(_ task: TPTaskInfo) {
		let destination: DownloadRequest.DownloadFileDestination = { _, _ in
			return (task.outputFile!, [.createIntermediateDirectories, .removePreviousFile])
		}
		
		Alamofire.download(task.resultUrl, to: destination)
			.downloadProgress(closure: { (progress) in
				self.updateStatus(task, newStatus: .downloading, progress: progress)
			})
			.response { response in
				let error = response.error
				if (error != nil) {
					self.markError(task, errorMessage: "download error")
				} else {
					self.updateStatus(task, newStatus: .finish)
					debugPrint("finish: " + task.fileName + " tasks: " + String(self.runningTasks))
				}
				
				self.checkExecution()
			}
	}
    
    fileprivate func credentialsError(_ task: TPTaskInfo, errorMessage: String?) {
        task.errorMessage = errorMessage
        updateStatus(task, newStatus: .credentials)
    }
	
	fileprivate func markError(_ task: TPTaskInfo, errorMessage: String?) {
		task.errorMessage = errorMessage
		updateStatus(task, newStatus: .error)
	}
	
	fileprivate func updateStatus(_ task: TPTaskInfo, newStatus: TPTaskStatus, progress: Progress) {
		task.status = newStatus
		task.progress = progress
		if newStatus == .error || newStatus == .finish || newStatus == .credentials {
			self.runningTasks -= 1
			if newStatus == .finish {
				self.finishTasksCount += 1
			}
		}
		callback.taskStatusChanged(task: task)
	}
	
	fileprivate func updateStatus(_ task: TPTaskInfo, newStatus: TPTaskStatus) {
		self.updateStatus(task, newStatus: newStatus, progress: Progress())
	}
}
