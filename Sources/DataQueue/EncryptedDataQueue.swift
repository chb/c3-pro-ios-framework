//
//  EncryptedDataQueue.swift
//  C3PRO
//
//  Created by Pascal Pfiffner on 8/21/15.
//  Copyright © 2015 Boston Children's Hospital. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import SMART


public protocol EncryptedDataQueueDelegate {
	
	func encryptedDataQueue(queue: EncryptedDataQueue, wantsEncryptionForResource resource: Resource, requestType: FHIRRequestType) -> Bool
	
	func keyIdentifierForEncryptedDataQueue(queue: EncryptedDataQueue) -> String?
}


/**
    Data Queue that can encrypt resources before sending.
 */
public class EncryptedDataQueue: DataQueue {
	
	/// An optional delegate to ask when to encrypt a resource and when not; if not provided, all resources will be encrypted.
	public var delegate: EncryptedDataQueueDelegate?
	
	/// The endpoint for encrypted resources; usually different from `baseURL` since these are not FHIR compliant.
	public internal(set) var encryptedBaseURL: NSURL
	
	let aes = AESUtility()
	
	let rsa: RSAUtility
	
	/**
	Designated initializer.
	
	- parameter baseURL: Base URL for the server's FHIR endpoint
	- parameter auth: OAuth2 settings
	- parameter encBaseURL: The base URL for encrypted resources
	- parameter publicCertificateFile: Filename, without ".crt" extension, of a bundled X509 public key certificate
	*/
	public init(baseURL: NSURL, auth: OAuth2JSON?, encBaseURL: NSURL, publicCertificateFile: String) {
		if let lastChar = encBaseURL.absoluteString.characters.last where "/" != lastChar {
			encryptedBaseURL = encBaseURL.URLByAppendingPathComponent("/")
		}
		else {
			encryptedBaseURL = encBaseURL
		}
		rsa = RSAUtility(publicCertificateFile: publicCertificateFile)
		super.init(baseURL: baseURL, auth: auth)
	}

	public required init(baseURL: NSURL, auth: OAuth2JSON?) {
	    fatalError("init(baseURL:auth:) cannot be used on `EncryptedDataQueue`, use init(baseURL:auth:encBaseURL:publicCertificateFile:)")
	}
	
	
	// MARK: - Encryption
	
	/**
	Encrypts the given data (which is presumed to be JSON data of a FHIR resource), then creates a JSON representation that also contains
	the encrypted symmetric key and a FHIR version flag and returns data produced when serializing that JSON.
	
	- parameter data: The data to encrypt, presumed to be NSData of a JSON-serialized FHIR resource
	- returns: NSData representing JSON
	*/
	public func encryptedData(data: NSData) throws -> NSData {
		let encData = try aes.encrypt(data)
		let encKey = try rsa.encrypt(aes.symmetricKeyData)
		let dict = [
			"key_id": delegate?.keyIdentifierForEncryptedDataQueue(self) ?? "",
			"symmetric_key": encKey.base64EncodedStringWithOptions([]),
			"message": encData.base64EncodedStringWithOptions([]),
			"version": C3PROFHIRVersion,
		]
		return try NSJSONSerialization.dataWithJSONObject(dict, options: [])
	}
	
	
	// MARK: - Requests
	
	public override func handlerForRequestOfType(type: FHIRRequestType, resource: Resource?) -> FHIRServerRequestHandler? {
		if let resource = resource where nil == delegate || delegate!.encryptedDataQueue(self, wantsEncryptionForResource: resource, requestType: type) {
			return EncryptedJSONRequestHandler(type, resource: resource, dataQueue: self)
		}
		return super.handlerForRequestOfType(type, resource: resource)
	}
	
	public override func absoluteURLForPath(path: String, handler: FHIRServerRequestHandler) -> NSURL? {
		if handler is EncryptedJSONRequestHandler {
			return NSURL(string: path, relativeToURL: encryptedBaseURL)
		}
		return super.absoluteURLForPath(path, handler: handler)
	}
}


public class EncryptedJSONRequestHandler: FHIRServerJSONRequestHandler {
	
	let dataQueue: EncryptedDataQueue
	
	init(_ type: FHIRRequestType, resource: Resource?, dataQueue: EncryptedDataQueue) {
		self.dataQueue = dataQueue
		super.init(type, resource: resource)
	}
	
	public override func prepareData() throws {
		data = nil					// to avoid double-encryption
		try super.prepareData()
		if let data = data {
			self.data = try dataQueue.encryptedData(data)
		}
	}
}
