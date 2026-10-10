//
//  ProbeSimulatorPayload.swift
//  ProbeSimulatorPayload
//
//  Stands in for the RuntimeViewerMobileServer payload in the single-build
//  test: an iOS Simulator framework that links a package. It is built and
//  embedded, not loaded.
//

import Foundation
import ProbeLibrary

public enum ProbeSimulatorPayload {
    public static var description: String {
        "payload linking ProbeLibrary built for \(ProbeLibrary.builtFor)"
    }
}
