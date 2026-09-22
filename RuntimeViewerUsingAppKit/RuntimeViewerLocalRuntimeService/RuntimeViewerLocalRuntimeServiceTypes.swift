//
//  RuntimeViewerLocalRuntimeServiceTypes.swift
//  RuntimeViewerLocalRuntimeService
//
//  Created by JH on 2026/9/21.
//

// A sample codable type that contains two numbers to be added together.
struct CalculationRequest: Codable {
    let firstNumber: Int
    let secondNumber: Int
}

// A sample codable type that contains the result of a calculation.
struct CalculationResponse: Codable {
    let result: Int
}
