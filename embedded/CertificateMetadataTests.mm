#import <Foundation/Foundation.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pem.h>
#include "CertificateMetadata.mm.inc"

static void require(BOOL success, NSString *message) {
    if (!success) { NSLog(@"FAILED: %@", message); exit(1); }
}

int main(int argc, const char **argv) { @autoreleasepool {
    require(argc == 2, @"PEM fixture required");
    BIO *input = BIO_new_file(argv[1], "r");
    X509 *certificate = PEM_read_bio_X509(input, NULL, NULL, NULL);
    require(certificate != NULL, @"Readable X.509 certificate");
    NSDictionary *metadata = si_certificate_metadata(certificate);
    require([metadata[@"team"] isEqual:@"ABCDEFGHIJ"], @"Read team directly from the actual X.509 OU");
    NSDate *expiry = metadata[@"expiresAt"];
    require([expiry isKindOfClass:NSDate.class] && expiry.timeIntervalSinceNow > 0 && expiry.timeIntervalSinceNow <= 86401,
            @"UTC expiry comes from the certificate independently of online status");
    X509 *noTeam = X509_new();
    NSDictionary *missing = si_certificate_metadata(noTeam);
    require(!missing[@"team"], @"Missing OU is unavailable metadata, never a fabricated team");
    require(si_certificate_metadata(NULL) == nil, @"No certificate means no metadata");
    X509_free(noTeam); X509_free(certificate); BIO_free(input);
    puts("Production X.509 team and UTC expiry metadata checks passed");
    return 0;
} }
