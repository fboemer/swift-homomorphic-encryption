// Copyright 2024-2025 Apple Inc. and the Swift Homomorphic Encryption project authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import _TestUtilities
import HomomorphicEncryption
@testable import PrivateInformationRetrieval
import Testing

@Suite
struct PirUtilTests {
    private func expandCiphertextForOneStepTest<Scheme: HeScheme>(
        scheme _: Scheme.Type,
        _ keyCompression: PirKeyCompressionStrategy) throws
    {
        let degree = 32
        let encryptionParameters = try EncryptionParameters<Scheme>(
            polyDegree: degree,
            plaintextModulus: Scheme.Scalar(17),
            coefficientModuli: Scheme.Scalar
                .generatePrimes(
                    significantBitCounts: Array(
                        repeating: Scheme.Scalar.bitWidth - 4,
                        count: 4),
                    preferringSmall: false,
                    nttDegree: degree),
            errorStdDev: ErrorStdDev.stdDev32,
            securityLevel: SecurityLevel.unchecked)

        let context: Context<Scheme> = try Context(encryptionParameters: encryptionParameters)
        let plaintextModulus = context.plaintextModulus
        let logDegree = degree.log2
        for logStep in 1...logDegree {
            let step = 1 << logStep
            let halfStep = step >> 1
            let data: [Scheme.Scalar] = TestUtils.getRandomPlaintextData(
                count: degree,
                in: 0..<plaintextModulus)
            let plaintext: Plaintext<Scheme, Coeff> = try context.encode(values: data, format: .coefficient)
            let secretKey = try context.generateSecretKey()

            let expandedQueryCount = degree
            let EvaluationKeyConfig = MulPir<Scheme>.evaluationKeyConfig(
                expandedQueryCount: expandedQueryCount,
                degree: degree,
                keyCompression: keyCompression)
            let evaluationKey = try context.generateEvaluationKey(
                config: EvaluationKeyConfig, using: secretKey)
            let ciphertext = try plaintext.encrypt(using: secretKey)
            let expandedCiphertexts = try PirUtil.expandCiphertextForOneStep(
                ciphertext,
                logStep: logStep,
                using: evaluationKey)
            let p0: [Scheme.Scalar] = try expandedCiphertexts.0.decrypt(using: secretKey).decode(format: .coefficient)
            let p1: [Scheme.Scalar] = try expandedCiphertexts.1.decrypt(using: secretKey).decode(format: .coefficient)

            for index in stride(from: 0, to: degree, by: step) {
                #expect(data[index].multiplyMod(2, modulus: plaintextModulus, variableTime: true) == p0[index])
                #expect(data[index + halfStep].multiplyMod(2, modulus: plaintextModulus, variableTime: true)
                    == p1[index])
            }
        }
    }

    private func expandCiphertextTest<Scheme: HeScheme>(scheme _: Scheme.Type) throws {
        let context: Context<Scheme> = try TestUtils.getTestContext()
        let degree = context.degree
        let logDegree = degree.log2
        for inputCount in 1...degree {
            let data: [Scheme.Scalar] = (0..<inputCount).map { _ in Scheme.Scalar(Int.random(in: 0...1)) }
            let nonZeroInputs = data.enumerated().compactMap { $0.element == 0 ? nil : $0.offset }
            let plaintext: Plaintext<Scheme, Coeff> = try PirUtil.compressInputsForOneCiphertext(
                totalInputCount: inputCount,
                nonZeroInputs: nonZeroInputs,
                context: context)
            let secretKey = try context.generateSecretKey()
            let evaluationKeyConfig = EvaluationKeyConfig(galoisElements: (1...logDegree).map { (1 << $0) + 1 })
            let evaluationKey = try context.generateEvaluationKey(config: evaluationKeyConfig, using: secretKey)
            let ciphertext = try plaintext.encrypt(using: secretKey)
            let expandedCiphertexts = try PirUtil.expandCiphertext(
                ciphertext,
                outputCount: inputCount,
                logStep: 1,
                expectedHeight: inputCount.ceilLog2,
                using: evaluationKey)
            #expect(expandedCiphertexts.count == inputCount)
            for index in 0..<inputCount {
                let decodedData: [Scheme.Scalar] = try expandedCiphertexts[index].decrypt(using: secretKey)
                    .decode(format: .coefficient)
                #expect(decodedData[0] == data[index])
                for coeff in decodedData.dropFirst() {
                    #expect(coeff == 0)
                }
            }
        }
    }

    private func expandCiphertextsTest<Scheme: HeScheme>(scheme _: Scheme.Type) throws {
        let context: Context<Scheme> = try TestUtils.getTestContext()
        let degree = TestUtils.testPolyDegree
        let logDegree = degree.log2
        for inputCount in 1...degree * 2 {
            let data: [Int] = (0..<inputCount).map { _ in Int.random(in: 0...1) }
            let nonZeroInputs = data.enumerated().compactMap { $0.element == 0 ? nil : $0.offset }
            let secretKey = try context.generateSecretKey()
            let ciphertexts = try PirUtil.compressInputs(
                totalInputCount: inputCount,
                nonZeroInputs: nonZeroInputs,
                context: context,
                using: secretKey)
            let evaluationKeyConfig = EvaluationKeyConfig(galoisElements: (1...logDegree).map { (1 << $0) + 1 })
            let evaluationKey = try context.generateEvaluationKey(
                config: evaluationKeyConfig,
                using: secretKey)
            let expandedCiphertexts = try PirUtil.expandCiphertexts(
                ciphertexts,
                outputCount: inputCount,
                using: evaluationKey)
            #expect(expandedCiphertexts.count == inputCount)
            for index in 0..<inputCount {
                let decodedData: [Scheme.Scalar] = try expandedCiphertexts[index].decrypt(using: secretKey)
                    .decode(format: .coefficient)
                #expect(Int(decodedData[0]) == data[index])
                for coeff in decodedData.dropFirst() {
                    #expect(coeff == 0)
                }
            }
        }
    }

    @Test
    func expandCiphertextForOneStepNoCompression() throws {
        try expandCiphertextForOneStepTest(scheme: NoOpScheme.self, .noCompression)
        try expandCiphertextForOneStepTest(scheme: Bfv<UInt32>.self, .noCompression)
        try expandCiphertextForOneStepTest(scheme: Bfv<UInt64>.self, .noCompression)
    }

    @Test
    func expandCiphertextForOneStepHybridCompression() throws {
        try expandCiphertextForOneStepTest(scheme: NoOpScheme.self, .hybridCompression)
        try expandCiphertextForOneStepTest(scheme: Bfv<UInt32>.self, .hybridCompression)
        try expandCiphertextForOneStepTest(scheme: Bfv<UInt64>.self, .hybridCompression)
    }

    @Test
    func expandCiphertextForOneStepMaxCompression() throws {
        try expandCiphertextForOneStepTest(scheme: NoOpScheme.self, .maxCompression)
        try expandCiphertextForOneStepTest(scheme: Bfv<UInt32>.self, .maxCompression)
        try expandCiphertextForOneStepTest(scheme: Bfv<UInt64>.self, .maxCompression)
    }

    @Test
    func expandCiphertext() throws {
        try expandCiphertextTest(scheme: NoOpScheme.self)
        try expandCiphertextTest(scheme: Bfv<UInt32>.self)
        try expandCiphertextTest(scheme: Bfv<UInt64>.self)
    }

    @Test
    func expandCiphertexts() throws {
        try expandCiphertextsTest(scheme: NoOpScheme.self)
        try expandCiphertextsTest(scheme: Bfv<UInt32>.self)
        try expandCiphertextsTest(scheme: Bfv<UInt64>.self)
    }
}
