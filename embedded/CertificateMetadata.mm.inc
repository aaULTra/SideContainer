// Public metadata comes directly from the X.509 leaf. ASN.1 strings are
// length-delimited and can lack a trailing NUL.
static NSDictionary *si_certificate_metadata(X509 *certificate) {
    if (!certificate) return nil;
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    X509_NAME *subject = X509_get_subject_name(certificate);
    int index = X509_NAME_get_index_by_NID(subject, NID_organizationalUnitName, -1);
    if (index >= 0) {
        ASN1_STRING *value = X509_NAME_ENTRY_get_data(X509_NAME_get_entry(subject, index));
        NSString *team = [[NSString alloc] initWithBytes:ASN1_STRING_get0_data(value)
            length:ASN1_STRING_length(value) encoding:NSUTF8StringEncoding];
        if (team.length) metadata[@"team"] = team;
    }
    struct tm expiry = {};
    if (ASN1_TIME_to_tm(X509_get0_notAfter(certificate), &expiry) == 1) {
        metadata[@"expiresAt"] = [NSDate dateWithTimeIntervalSince1970:timegm(&expiry)];
    }
    return metadata;
}
