//
//  SIPChecker.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2025/4/2.
//

import Foundation

enum SIPChecker {

    static func isDisabled() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/csrutil"
        task.arguments = ["status"]

        let pipe = Pipe()
        task.standardOutput = pipe

        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let output = String(data: data, encoding: .utf8) else { return false }

        return output.contains("disabled")
    }
}
