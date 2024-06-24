//
//  RuntimeVieweriOSHelperService.swift
//  RuntimeVieweriOSHelperService
//
//  Created by JH on 2024/6/24.
//

import Foundation
import RuntimeViewerCore

/// This object implements the protocol which we have defined. It provides the actual behavior for the service. It is 'exported' by the service to make it available to the process hosting the service over an NSXPCConnection.
class RuntimeVieweriOSHelperService: NSObject, RuntimeVieweriOSHelperServiceProtocol {
    
    /// This implements the example protocol. Replace the body of this class with the implementation of this service's protocol.
    @objc func performCalculation(firstNumber: Int, secondNumber: Int, with reply: @escaping (Int) -> Void) {
        let response = firstNumber + secondNumber
        reply(response)
    }
    public struct DlOpenError: Error {
        public let message: String?
    }
    @objc func loadImage(_ imagePath: String, with reply: (Error?) -> Void) {
        do {
//            try CDUtilities.loadImage(at: imagePath)
            
            try imagePath.withCString { cString in
                let handle = dlopen(cString, RTLD_LAZY)
                // get the error and copy it into an object we control since the error is shared
                let errPtr = dlerror()
                let errStr = errPtr.map { String(cString: $0) }
                guard handle != nil else {
                    throw DlOpenError(message: errStr)
                }
            }
            reply(nil)
        } catch {
            reply(error)
        }
    }
    
    @objc func queryClassList(with reply: @escaping ([String]) -> Void) {
        reply(RuntimeListings.shared.classList)
    }
}
