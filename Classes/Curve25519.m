//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "Curve25519.h"
#import <SignalCoreKit/OWSAsserts.h>
#import <SignalCoreKit/Randomness.h>
#import <SignalCoreKit/SCKExceptionWrapper.h>
#import "ge.h"
#import "crypto_hash_sha512.h"
#import "crypto_sign.h"

NS_ASSUME_NONNULL_BEGIN


NSErrorDomain const Curve25519KitErrorDomain = @"Curve25519KitErrorDomain";

NSString *const TSECKeyPairPublicKey = @"TSECKeyPairPublicKey";
NSString *const TSECKeyPairPrivateKey = @"TSECKeyPairPrivateKey";
NSString *const TSECKeyPairPreKeyId = @"TSECKeyPairPreKeyId";

extern void curve25519_donna(unsigned char *output, const unsigned char *a, const unsigned char *b);

extern int curve25519_sign(unsigned char *signature_out, /* 64 bytes */
    const unsigned char *curve25519_privkey, /* 32 bytes */
    const unsigned char *msg,
    const unsigned long msg_len,
    const unsigned char *random); /* 64 bytes */

@implementation ECKeyPair

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeBytes:self.publicKey.bytes length:ECCKeyLength forKey:TSECKeyPairPublicKey];
    [coder encodeBytes:self.privateKey.bytes length:ECCKeyLength forKey:TSECKeyPairPrivateKey];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    NSUInteger returnedLength = 0;
    const uint8_t *returnedBuffer = NULL;

    // De-serialize public key
    returnedBuffer = [coder decodeBytesForKey:TSECKeyPairPublicKey returnedLength:&returnedLength];
    if (returnedLength != ECCKeyLength) {
        OWSFailDebug(@"failure: wrong length for public key.");
        return nil;
    }
    NSData *publicKeyData = [NSData dataWithBytes:returnedBuffer length:returnedLength];

    // De-serialize private key
    returnedBuffer = [coder decodeBytesForKey:TSECKeyPairPrivateKey returnedLength:&returnedLength];
    if (returnedLength != ECCKeyLength) {
        OWSFailDebug(@"failure: wrong length for private key.");
        return nil;
    }
    NSData *privateKeyData = [NSData dataWithBytes:returnedBuffer length:returnedLength];

    NSError *error;
    ECKeyPair *keyPair = [self initWithPublicKeyData:publicKeyData
                                      privateKeyData:privateKeyData
                                               error:&error];
    if (error != nil) {
        OWSFailDebug(@"error: %@", error);
        return nil;
    }

    return keyPair;
}

/**
 * Build a keypair from existing key data.
 * If you need a *new* keypair, user `generateKeyPair` instead.
 */
- (nullable instancetype)initWithPublicKeyData:(NSData *)publicKeyData
                                privateKeyData:(NSData *)privateKeyData
                                         error:(NSError **)error
{
    if (self = [super init]) {
        if (publicKeyData.length != ECCKeyLength || privateKeyData.length != ECCKeyLength) {
            *error = [NSError errorWithDomain:Curve25519KitErrorDomain
                                         code:Curve25519KitError_InvalidKeySize
                                     userInfo:nil];
            return nil;
        }
        _publicKey = publicKeyData;
        _privateKey = privateKeyData;
    }
    return self;
}

+ (ECKeyPair *)generateKeyPair
{
    // Generate key pair as described in
    // https://code.google.com/p/curve25519-donna/
    NSMutableData *privateKey = [[Randomness generateRandomBytes:ECCKeyLength] mutableCopy];
    uint8_t *privateKeyBytes = privateKey.mutableBytes;
    privateKeyBytes[0] &= 248;
    privateKeyBytes[31] &= 127;
    privateKeyBytes[31] |= 64;

    static const uint8_t basepoint[ECCKeyLength] = { 9 };

    NSMutableData *publicKey = [NSMutableData dataWithLength:ECCKeyLength];
    if (!publicKey) {
        OWSFail(@"Could not allocate buffer");
    }

    curve25519_donna(publicKey.mutableBytes, privateKey.mutableBytes, basepoint);

    ECKeyPair *keyPair = [[ECKeyPair alloc] initWithPublicKeyData:[publicKey copy]
                                                   privateKeyData:[privateKey copy]
                                                            error:nil];
    OWSAssert(keyPair != nil);

    return keyPair;
}

- (NSData *)throws_sign:(NSData *)data
{
    if (!data) {
        OWSRaiseException(NSInvalidArgumentException, @"Missing data.");
    }

    NSMutableData *signatureData = [NSMutableData dataWithLength:ECCSignatureLength];
    if (!signatureData) {
        OWSFail(@"Could not allocate buffer");
    }

    NSData *randomBytes = [Randomness generateRandomBytes:64];

    if (curve25519_sign(
            signatureData.mutableBytes, self.privateKey.bytes, [data bytes], [data length], [randomBytes bytes])
        == -1) {
        OWSRaiseException(NSInternalInconsistencyException, @"Message couldn't be signed.");
    }

    return [signatureData copy];
}

@end


#pragma mark - For Channels

@implementation ECKeyPairChannels

+(ECKeyPairChannels*)generateKeyPairBySeed:(unsigned char*)seed {
    
    ECKeyPairChannels* keyPair = [[ECKeyPairChannels alloc] init];
    
    unsigned char hash[64];
    crypto_hash_sha512(hash, seed, ECCKeyLength);
    memcpy(keyPair->privateKey, hash, ECCKeyLength);
    keyPair->privateKey[0]  &= 248;
    keyPair->privateKey[31] &= 127;
    keyPair->privateKey[31] |= 64;
    
    static const uint8_t basepoint[ECCKeyLength] = {9};
    curve25519_donna(keyPair->publicKey, keyPair->privateKey, basepoint);
    
    ge_p3 A;
    ge_scalarmult_base(&A, keyPair->privateKey);
    ge_p3_tobytes(keyPair->publicKey, &A);
    
    return keyPair;
}

+ (BOOL)supportsSecureCoding{
    return YES;
}

-(NSData*) publicKey {
    return [NSData dataWithBytes:self->publicKey length:32];
}

-(void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeBytes:self->publicKey length:ECCKeyLength forKey:TSECKeyPairPublicKey];
    [coder encodeBytes:self->privateKey length:ECCKeyLength forKey:TSECKeyPairPrivateKey];
}

-(nullable id)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        NSUInteger returnedLength = 0;
        const uint8_t *returnedBuffer = NULL;
        // De-serialize public key
        returnedBuffer = [coder decodeBytesForKey:TSECKeyPairPublicKey returnedLength:&returnedLength];
        if (returnedLength != ECCKeyLength) {
            return nil;
        }
        memcpy(self->publicKey, returnedBuffer, ECCKeyLength);
        
        // De-serialize private key
        returnedBuffer = [coder decodeBytesForKey:TSECKeyPairPrivateKey returnedLength:&returnedLength];
        if (returnedLength != ECCKeyLength) {
            return nil;
        }
        memcpy(self->privateKey, returnedBuffer, ECCKeyLength);
    }
    return self;
}

@end

#pragma mark -

@implementation Curve25519

+ (ECKeyPair *)generateKeyPair
{
    return [ECKeyPair generateKeyPair];
}

+ (NSData *)throws_generateSharedSecretFromPublicKey:(NSData *)theirPublicKey andKeyPair:(ECKeyPair *)keyPair
{
    if (!keyPair) {
        OWSRaiseException(NSInvalidArgumentException, @"Missing key pair.");
    }

    return [self throws_generateSharedSecretFromPublicKey:theirPublicKey privateKey:keyPair.privateKey];
}

+ (nullable NSData *)generateSharedSecretFromPublicKey:(NSData *)publicKey
                                            privateKey:(NSData *)privateKey
                                                 error:(NSError **)outError
{
    @try {
        return [self throws_generateSharedSecretFromPublicKey:publicKey privateKey:privateKey];
    } @catch (NSException *exception) {
        *outError = SCKExceptionWrapperErrorMake(exception);
        return nil;
    }
}

+ (NSData *)throws_generateSharedSecretFromPublicKey:(NSData *)publicKey privateKey:(NSData *)privateKey
{
    if (publicKey.length != ECCKeyLength) {
        OWSRaiseException(
                          NSInvalidArgumentException, @"Public key has unexpected length: %lu", (unsigned long)publicKey.length);
    }
    if (privateKey.length != ECCKeyLength) {
        OWSRaiseException(
                          NSInvalidArgumentException, @"Private key has unexpected length: %lu", (unsigned long)privateKey.length);
    }

    NSMutableData *sharedSecretData = [NSMutableData dataWithLength:32];
    if (!sharedSecretData) {
        OWSFail(@"Could not allocate buffer");
    }

    curve25519_donna(sharedSecretData.mutableBytes, privateKey.bytes, publicKey.bytes);

    return [sharedSecretData copy];
}

#pragma mark - For Channels

+(ECKeyPairChannels*)generateKeyPairBySeed:(unsigned char*)seed {
    return [ECKeyPairChannels generateKeyPairBySeed:seed];
}

+ (NSData*)signatures:(NSData*)secretKey message:(NSData*)message {
    const unsigned char *m = [message bytes];
    unsigned long long mlen = [message length];
    const unsigned char *sk = [secretKey bytes];
    unsigned long long smlen_p;
    NSMutableData *sigData = [NSMutableData dataWithLength:crypto_sign_BYTES + mlen];
    unsigned char *sig = [sigData mutableBytes];
    crypto_sign(sig, &smlen_p, m, mlen, sk);
    NSMutableData *outData = [NSMutableData dataWithLength:crypto_sign_BYTES];
    unsigned char *outD = [outData mutableBytes];
    memcpy(outD, sig, crypto_sign_BYTES);
    return outData;
}

+ (NSData*)cryptoHashSha512:(NSData*)publicKey {
    NSMutableData *outData = [NSMutableData dataWithLength:64];
    unsigned char *hash = [outData mutableBytes];
    crypto_hash_sha512(hash, [publicKey bytes], ECCKeyLength);
    return outData;
}

+ (void)cryptoHashSha512:(unsigned char*)hash publicKey:(unsigned char*)publicKey {
    crypto_hash_sha512(hash, publicKey, ECCKeyLength);
}

@end

NS_ASSUME_NONNULL_END
