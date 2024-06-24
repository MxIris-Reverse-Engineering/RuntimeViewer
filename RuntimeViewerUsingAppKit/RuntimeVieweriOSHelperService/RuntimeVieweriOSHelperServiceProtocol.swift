//
//  RuntimeVieweriOSHelperServiceProtocol.swift
//  RuntimeVieweriOSHelperService
//
//  Created by JH on 2024/6/24.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol RuntimeVieweriOSHelperServiceProtocol {
    
    /// Replace the API of this protocol with an API appropriate to the service you are vending.
    func performCalculation(firstNumber: Int, secondNumber: Int, with reply: @escaping (Int) -> Void)
    func loadImage(_ imagePath: String, with reply: @escaping (Error?) -> Void)
    func queryClassList(with reply: @escaping ([String]) -> Void)
}

/*
 To use the service from an application or other process, use NSXPCConnection to establish a connection to the service by doing something like this:

     connectionToService = NSXPCConnection(serviceName: "com.JH.RuntimeVieweriOSHelperService")
     connectionToService.remoteObjectInterface = NSXPCInterface(with: RuntimeVieweriOSHelperServiceProtocol.self)
     connectionToService.resume()

 Once you have a connection to the service, you can use it like this:

     if let proxy = connectionToService.remoteObjectProxy as? RuntimeVieweriOSHelperServiceProtocol {
         proxy.performCalculation(firstNumber: 23, secondNumber: 19) { result in
             NSLog("Result of calculation is: \(result)")
         }
     }

 And, when you are finished with the service, clean up the connection like this:

     connectionToService.invalidate()
*/
