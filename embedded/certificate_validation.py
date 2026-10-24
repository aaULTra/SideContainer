"""Checked fixes to upstream's certificate diagnostics; never bypass trust checks."""

def patch(root, replace):
    signer = root / "ZSign/zsign.mm"
    from pathlib import Path
    import shutil
    shutil.copyfile(Path(__file__).with_name('CertificateMetadata.mm.inc'), root / 'ZSign/SICertificateMetadata.inc')
    replace(signer, '#include "zsigner.h"', '#include "zsigner.h"\n#include "SICertificateMetadata.inc"', 1)
    replace(signer, '    // Extract OCSP URL from cert', '''    NSDictionary *metadata = si_certificate_metadata(cert);
    NSString *organizationalUnitName = metadata[@"team"];
    NSDate *expirationDate = metadata[@"expiresAt"];
    // Extract OCSP URL from cert''', 1)
    replace(signer, '    NSString* teamId = [NSString stringWithUTF8String:zSignAsset.m_strTeamId.c_str()];\n    return teamId;',
            '    return si_certificate_metadata((X509*)zSignAsset.m_x509Cert)[@"team"];', 1)
    replace(signer, '@implementation ZSigner', '''@implementation ZSigner
+ (NSDictionary *)certificateInfoWithCert:(NSData *)data pass:(NSString *)password {
    if (!data.length || !password) return nil;
    ZSignAsset asset;
    if (!asset.InitSimple((const char *)data.bytes, (int)data.length, nil, 0, std::string(password.UTF8String))) return nil;
    return si_certificate_metadata((X509 *)asset.m_x509Cert);
}
''', 1)
    replace(root / 'ZSign/zsigner.h', '@interface ZSigner : NSObject',
            '@interface ZSigner : NSObject\n+ (NSDictionary *)certificateInfoWithCert:(NSData *)data pass:(NSString *)password;', 1)
    old_start = '            ASN1_TIME *expirationDateAsn1 = X509_get_notAfter(cert);'
    old_end = '            formatter.locale = NSLocale.currentLocale;\n            NSDate *expirationDate = [formatter dateFromString:fullDateString];'
    source = signer.read_text()
    start, end = source.index(old_start), source.index(old_end) + len(old_end)
    replace(signer, source[start:end], '', 1)
    old = '    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:(const char *)uri->data]]];'
    replace(signer, old, '''    // ASN.1 strings are length-delimited, not C strings. Decode exactly its bytes.
    NSString *uriString = [[NSString alloc] initWithBytes:ASN1_STRING_get0_data(uri)
        length:ASN1_STRING_length(uri) encoding:NSASCIIStringEncoding];
    NSURL *url = uriString ? [NSURL URLWithString:uriString] : nil;
    if (!url.host.length || !([url.scheme.lowercaseString isEqualToString:@"http"] ||
                             [url.scheme.lowercaseString isEqualToString:@"https"])) {
        OPENSSL_free(der);
        OCSP_REQUEST_free(req);
        OCSP_CERTID_free(cert_id);
        sk_ACCESS_DESCRIPTION_pop_free(aia, ACCESS_DESCRIPTION_free);
        X509_free(issuer);
        BIO_free(brother1);
        completionHandler(2, expirationDate, organizationalUnitName,
                          @"Certificate revocation URL is missing or malformed. Certificate metadata remains readable; revocation status is unknown.");
        return -7;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 20;''', 1)
    replace(signer, 'completionHandler(2, nil, nil, error.localizedDescription);',
            'OCSP_CERTID_free(cert_id);\n            completionHandler(2, expirationDate, organizationalUnitName, '
            '[NSString stringWithFormat:@"Revocation check failed (%@ %ld): %@. URL: %@", '
            'error.domain, (long)error.code, error.localizedDescription, url.absoluteString]);', 1)
    replace(signer, 'completionHandler(2, nil, nil, @"Failed to decode OCSP response.");',
            'OCSP_CERTID_free(cert_id);\n                completionHandler(2, expirationDate, organizationalUnitName, @"Failed to decode OCSP response.");', 1)
    replace(signer, '            int status, reason;\n            if (OCSP_resp_find_status',
            '            if (!basic) {\n'
            '                OCSP_RESPONSE_free(resp); OCSP_CERTID_free(cert_id);\n'
            '                completionHandler(2, expirationDate, organizationalUnitName, @"No basic OCSP response."); return;\n'
            '            }\n            int status, reason;\n            if (OCSP_resp_find_status', 1)
    replace(signer, 'completionHandler(2, nil, nil, @"Invalid response or no data");',
            'OCSP_CERTID_free(cert_id);\n            completionHandler(2, expirationDate, organizationalUnitName, '
            '[NSString stringWithFormat:@"Revocation server returned HTTP %ld or no response data", (long)httpResponse.statusCode]);', 1)

    diagnose = root / "LiveContainerSwiftUI/Views/Settings/LCJITLessDiagnoseView.swift"
    settings = root / "LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift"
    replace(settings, '    func onSideStoreCertificateCallback(certificateData: Data, password: String) {',
            '    func onSideStoreCertificateCallback(certificateData: Data, password: String) {\n'
            '        guard let team = LCUtils.getCertTeamId(withKeyData: certificateData, password: password) else {\n'
            '            errorInfo = "The shared certificate/private key could not be decoded with its password. The existing certificate was kept."\n'
            '            errorShow = true; return\n'
            '        }\n'
            '        guard team == LCSharedUtils.teamIdentifier() else {\n'
            '            errorInfo = "Shared certificate team: \\(team). Host team: \\(LCSharedUtils.teamIdentifier() ?? "unavailable"). The existing certificate was kept."\n'
            '            errorShow = true; return\n'
            '        }', 1)
    replace(diagnose, '        LCUtils.validateCertificate { status, date, ou, error in\n',
            '        LCUtils.validateCertificate { status, date, ou, error in\n'
            '            if let ou { certTeamId = ou }\n'
            '            if let date {\n'
            '                let formatter = DateFormatter()\n'
            '                formatter.dateStyle = .short; formatter.timeStyle = .medium\n'
            '                certificateValidateUntil = formatter.string(from: date)\n'
            '            }\n', 1)

    macho = root / "LiveContainer/LCMachOUtils.m"
    replace(macho, 'bool checkCodeSignature(const char* path) {',
            'bool checkCodeSignature(const char* path) {\n'
            '    [NSUserDefaults.standardUserDefaults setObject:@"No readable ARM64 code signature found." forKey:@"SILastSignatureError"];', 1)
    replace(macho, '        if ( addFileSigsReault == -1 ) {',
            '        if ( addFileSigsReault == -1 ) {\n'
            '            int savedErrno = errno;\n'
            '            [NSUserDefaults.standardUserDefaults setObject:[NSString stringWithFormat:@"F_ADDFILESIGS_RETURN failed: errno %d (%s)", savedErrno, strerror(savedErrno)] forKey:@"SILastSignatureError"];', 1)
    replace(macho, '        int checkLVresult = fcntl(fd, F_CHECK_LV, &checkInfo);',
            '        int checkLVresult = fcntl(fd, F_CHECK_LV, &checkInfo);\n'
            '        if (checkLVresult != 0) {\n'
            '            int savedErrno = errno;\n'
            '            NSString *detail = [[NSString alloc] initWithBytes:messageBuffer length:strnlen(messageBuffer, sizeof(messageBuffer)) encoding:NSUTF8StringEncoding];\n'
            '            [NSUserDefaults.standardUserDefaults setObject:[NSString stringWithFormat:@"F_CHECK_LV failed: errno %d (%s). %@", savedErrno, strerror(savedErrno), detail ?: @"No library-validation message"] forKey:@"SILastSignatureError"];\n'
            '        }', 1)
    utils = root / "LiveContainerSwiftUI/Utilities/LCUtils.m"

    replace(utils, '+ (NSString*)getCertTeamIdWithKeyData:', '''+ (NSDictionary *)embeddedCertificateMetadata {
    NSError *error = nil;
    [self loadStoreFrameworksWithError2:&error];
    if (error) return nil;
    NSData *data = self.certificateData;
    NSString *password = LCSharedUtils.certificatePassword;
    if (!data.length || !password) return nil;
    return [NSClassFromString(@"ZSigner") certificateInfoWithCert:data pass:password];
}

+ (NSString*)getCertTeamIdWithKeyData:''', 1)
    # One host API serves both the built-in setup screen and manual LC import.
    fragment = (__import__('pathlib').Path(__file__).parent / 'SigningSetup.m.inc').read_text()
    replace(utils, '@implementation LCUtils', '@implementation LCUtils\n' + fragment, 1)
    header = root / 'LiveContainerSwiftUI/Utilities/LCUtils.h'
    replace(header, '@interface LCUtils : NSObject', '''@interface LCUtils : NSObject
+ (NSDictionary * _Nullable)embeddedCertificateMetadata;\n+ (NSString * _Nullable)embeddedCertificateError:(NSData *)p12 password:(NSString *)password hostBundle:(NSBundle *)host;
+ (NSString * _Nullable)embeddedActivateCertificate:(NSData *)p12 password:(NSString *)password hostBundle:(NSBundle *)host;
+ (void)embeddedValidateJITLessWithHostBundle:(NSBundle *)host completion:(void (^)(BOOL, NSError * _Nullable))completion;
''', 1)
    source = utils.read_text()
    start = source.index('+ (void)validateJITLessSetupWithCompletionHandler:')
    end = source.index('+ (NSURL *)archiveIPAWithBundleName:', start)
    replace(utils, source[start:end], '''+ (void)validateJITLessSetupWithCompletionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    [self embeddedValidateJITLessWithHostBundle:NSBundle.mainBundle completion:completionHandler];
}

''', 1)
    replace(settings, '        LCUtils.appGroupUserDefault.set(certificateData, forKey: "LCCertificateData")\n        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")\n        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")',
            '''        if let issue = LCUtils.embeddedActivateCertificate(certificateData, password: password, hostBundle: Bundle.main) {
            errorInfo = issue; errorShow = true; return
        }''', 1)
    replace(diagnose, 'Text("SideStore")', 'Text("SideInstaller")', 1)
    replace(diagnose, '"lc.jitlessSetup.error.testLibLoadFailed %@ %@ %@".localizeWithFormat(storeName, storeName, storeName) + "\\n" + (error?.localizedDescription ?? "")',
            '"Signing test failed. Open the built-in SideInstaller → Set up LiveContainer → Check signing for details.\\n\\n" + (error?.localizedDescription ?? "No error details were returned.")', 1)

    replace(utils, '    NSUserDefaults* nud = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];',
            '    NSUserDefaults* nud = NSUserDefaults.lcSharedDefaults ?: [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];', 1)
    replace(utils, '    void* handle = dlopen("@executable_path/Frameworks/ZSign.dylib", RTLD_GLOBAL);',
            '''    // Guest dyld hooks may resolve @executable_path inside SideInstaller.
    NSBundle *host = NSUserDefaults.lcMainBundle ?: NSBundle.mainBundle;
    if (NSUserDefaults.isLiveProcess) {
        host = [NSBundle bundleWithURL:host.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
    }
    NSString *signer = [host.bundlePath stringByAppendingPathComponent:@"Frameworks/ZSign.dylib"];
    void* handle = dlopen(signer.fileSystemRepresentation, RTLD_GLOBAL);''', 1)

    # Metadata is local. Online OCSP diagnostics are optional and cannot turn
    # an unreachable responder into a revoked certificate or a failed setup.
    replace(diagnose, '    @State var certificateValidateUntil : String? = nil',
            '    @State var certificateValidateUntil : String? = nil\n'
            '    @State private var certificateExpiryDate: Date?\n'
            '    @State private var onlineStatusMessage: String?\n'
            '    @State private var onlineCheckAttempted = false', 1)
    replace(diagnose, '            validateCertificate()', '            loadCertificateMetadata()', 1)
    replace(diagnose, '.foregroundStyle(certificateStatus == 0 ? .green : .red)',
            '.foregroundStyle(certificateStatus == 0 ? .green : (certificateStatus == 1 ? .red : .orange))', 2)
    source = diagnose.read_text()
    date_start = source.index('Text(certificateValidateUntil != nil ?')
    date_end = source.index('.foregroundStyle(certificateStatus', date_start)
    line_end = source.index('\n', date_end)
    replace(diagnose, source[date_start:line_end],
            source[date_start:date_end] + '.foregroundStyle(certificateExpiryDate == nil ? Color.gray : (certificateExpiryDate! > Date() ? .green : .red))', 1)
    replace(diagnose, '                Section {\n                    Button {\n                        testJITLessMode()',
            '''                Section("Online certificate status") {
                    Text("This optional check is separate from the on-device signing test.")
                        .foregroundStyle(.secondary)
                    Button("Check online status") { validateCertificate() }
                        .disabled(certificateStatus == -1)
                    if let onlineStatusMessage {
                        Text("Online status unavailable. This does not mean the certificate is revoked.")
                            .foregroundStyle(.orange)
                        DisclosureGroup("Details") { Text(onlineStatusMessage).textSelection(.enabled) }
                    }
                }
                Section {
                    Button {
                        testJITLessMode()''', 1)
    source = diagnose.read_text()
    start = source.index('    func validateCertificate() {')
    end = source.index('    func getStatusText(', start)
    replace(diagnose, source[start:end], '''    func loadCertificateMetadata() {
        certificateStatus = 2
        onlineStatusMessage = nil
        onlineCheckAttempted = false
        guard let metadata = LCUtils.embeddedCertificateMetadata() else { return }
        certTeamId = metadata["team"] as? String
        certificateExpiryDate = metadata["expiresAt"] as? Date
        if let date = certificateExpiryDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .short; formatter.timeStyle = .medium
            certificateValidateUntil = formatter.string(from: date)
        }
    }

    func validateCertificate() {
        certificateStatus = -1
        onlineStatusMessage = nil
        onlineCheckAttempted = true
        LCUtils.validateCertificate { status, date, ou, error in
            DispatchQueue.main.async {
                if let ou { certTeamId = ou }
                if let date {
                    certificateExpiryDate = date
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short; formatter.timeStyle = .medium
                    certificateValidateUntil = formatter.string(from: date)
                }
                certificateStatus = error == nil ? Int(status) : 2
                onlineStatusMessage = error
            }
        }
    }

''', 1)
    replace(diagnose, 'return "lc.jitlessDiag.certificateValid".loc', 'return "Responder reports not revoked"', 1)
    # Only the online-status default, not unrelated Unknown fields.
    replace(diagnose, '        default:\n            return "lc.common.unknown".loc',
            '        default:\n            return onlineStatusMessage == nil ? (onlineCheckAttempted ? "Online status unknown" : "Not checked online") : "Online check unavailable"', 1)
    source = utils.read_text()
    start = source.index('+ (int)validateCertificateWithCompletionHandler:')
    end = source.index('#pragma mark JIT', start)
    replace(utils, source[start:end], '''+ (int)validateCertificateWithCompletionHandler:(void(^)(int, NSDate *, NSString *, NSString *))completionHandler {
    NSError *error = nil;
    [self loadStoreFrameworksWithError2:&error];
    NSData *data = self.certificateData;
    NSString *password = LCSharedUtils.certificatePassword;
    if (error || !data.length || !password) {
        completionHandler(2, nil, nil, error.localizedDescription ?: @"No readable certificate is available for the online check.");
        return -6;
    }
    return [NSClassFromString(@"ZSigner") checkCert:data pass:password completionHandler:completionHandler];
}

''', 1)
