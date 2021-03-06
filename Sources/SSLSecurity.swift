//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  SSLSecurity.swift
//  Starscream
//
//  Created by Dalton Cherry on 5/16/15.
//  Copyright (c) 2014-2015 Dalton Cherry.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
import Security

class SSLCert {
    var certData: Data?
    var key: SecKey?

    init(data: Data) {
        self.certData = data
    }

    init(key: SecKey) {
        self.key = key
    }
}

class SSLSecurity {
    var validatedDN = true //should the domain name be validated?

    var isReady = false //is the key processing done?
    var certificates: [Data]? //the certificates
    var pubKeys: [SecKey]? //the public keys
    var usePublicKeys = false //use public keys or certificate validation?

    convenience init(usePublicKeys: Bool = false) {
        let paths = Bundle.main.paths(forResourcesOfType: "cer", inDirectory: ".")

        let certs = paths.reduce(into: [SSLCert]()) { (certs: inout [SSLCert], path: String) in
            if let data = NSData(contentsOfFile: path) {
                certs.append(SSLCert(data: data as Data))
            }
        }

        self.init(certs: certs, usePublicKeys: usePublicKeys)
    }

    init(certs: [SSLCert], usePublicKeys: Bool) {
        self.usePublicKeys = usePublicKeys

        if self.usePublicKeys {
            DispatchQueue.global(qos: .default).async {
                let pubKeys = certs.reduce(into: [SecKey]()) { (pubKeys: inout [SecKey], cert: SSLCert) in
                    if let data = cert.certData, cert.key == nil {
                        cert.key = self.extractPublicKey(data)
                    }
                    if let key = cert.key {
                        pubKeys.append(key)
                    }
                }

                self.pubKeys = pubKeys
                self.isReady = true
            }
        } else {
            let certificates = certs.reduce(into: [Data]()) { (certificates: inout [Data], cert: SSLCert) in
                if let data = cert.certData {
                    certificates.append(data)
                }
            }
            self.certificates = certificates
            self.isReady = true
        }
    }

    func isValid(_ trust: SecTrust, domain: String?) -> Bool {

        var tries = 0
        while !self.isReady {
            usleep(1000)
            tries += 1
            if tries > 5 {
                return false //doesn't appear it is going to ever be ready...
            }
        }
        var policy: SecPolicy
        if self.validatedDN {
            policy = SecPolicyCreateSSL(true, domain as NSString?)
        } else {
            policy = SecPolicyCreateBasicX509()
        }
        SecTrustSetPolicies(trust, policy)
        if self.usePublicKeys {
            if let keys = self.pubKeys {
                let serverPubKeys = publicKeyChain(trust)
                for serverKey in serverPubKeys as [AnyObject] {
                    for key in keys as [AnyObject] {
                        if serverKey.isEqual(key) {
                            return true
                        }
                    }
                }
            }
        } else if let certs = self.certificates {
            let serverCerts = certificateChain(trust)
            var collect = [SecCertificate]()
            for cert in certs {
                collect.append(SecCertificateCreateWithData(nil, cert as CFData)!)
            }
            SecTrustSetAnchorCertificates(trust, collect as NSArray)
            var result: SecTrustResultType = .unspecified
            SecTrustEvaluate(trust, &result)
            if result == .unspecified || result == .proceed {
                var trustedCount = 0
                for serverCert in serverCerts {
                    for cert in certs {
                        if cert == serverCert {
                            trustedCount += 1
                            break
                        }
                    }
                }
                if trustedCount == serverCerts.count {
                    return true
                }
            }
        }
        return false
    }

    func extractPublicKey(_ data: Data) -> SecKey? {
        guard let cert = SecCertificateCreateWithData(nil, data as CFData) else { return nil }

        return extractPublicKey(cert, policy: SecPolicyCreateBasicX509())
    }

    func extractPublicKey(_ cert: SecCertificate, policy: SecPolicy) -> SecKey? {
        var possibleTrust: SecTrust?
        SecTrustCreateWithCertificates(cert, policy, &possibleTrust)

        guard let trust = possibleTrust else { return nil }

        var result: SecTrustResultType = .unspecified
        SecTrustEvaluate(trust, &result)
        return SecTrustCopyPublicKey(trust)
    }

    func certificateChain(_ trust: SecTrust) -> [Data] {
        let certificates = (0..<SecTrustGetCertificateCount(trust)).reduce(into: [Data]()) { (certificates: inout [Data], index: Int) in
            let cert = SecTrustGetCertificateAtIndex(trust, index)
            certificates.append(SecCertificateCopyData(cert!) as Data)
        }

        return certificates
    }

    func publicKeyChain(_ trust: SecTrust) -> [SecKey] {
        let policy = SecPolicyCreateBasicX509()
        let keys = (0..<SecTrustGetCertificateCount(trust)).reduce(into: [SecKey]()) { (keys: inout [SecKey], index: Int) in
            let cert = SecTrustGetCertificateAtIndex(trust, index)
            if let key = extractPublicKey(cert!, policy: policy) {
                keys.append(key)
            }
        }

        return keys
    }
}
