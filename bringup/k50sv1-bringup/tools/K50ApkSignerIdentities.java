/*
 * Emit the verified active and proof-of-rotation APK signer identities.
 * Certificate identity alone is insufficient: a compromised private key can
 * be wrapped in a freshly issued X.509 certificate, so callers also consume
 * the SHA-256 of SubjectPublicKeyInfo (PublicKey.getEncoded()).
 */

import com.android.apksig.ApkVerifier;
import com.android.apksig.SigningCertificateLineage;
import java.io.File;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class K50ApkSignerIdentities {
    private K50ApkSignerIdentities() {}

    private static final class Identity {
        final String role;
        final X509Certificate certificate;

        Identity(String role, X509Certificate certificate) {
            this.role = role;
            this.certificate = certificate;
        }
    }

    private static String sha256(byte[] value) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(value);
        StringBuilder result = new StringBuilder(digest.length * 2);
        for (byte element : digest) {
            result.append(String.format("%02x", element & 0xff));
        }
        return result.toString();
    }

    private static void add(
            Map<String, Identity> identities, String role, X509Certificate certificate)
            throws Exception {
        String certificateSha = sha256(certificate.getEncoded());
        if (!identities.containsKey(certificateSha)) {
            identities.put(certificateSha, new Identity(role, certificate));
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: K50ApkSignerIdentities <apk>");
            System.exit(2);
        }

        ApkVerifier.Result verification =
                new ApkVerifier.Builder(new File(args[0])).build().verify();
        if (!verification.isVerified()) {
            System.err.println("APK signature does not verify: " + verification.getErrors());
            System.exit(1);
        }

        LinkedHashMap<String, Identity> identities = new LinkedHashMap<>();
        List<X509Certificate> activeSigners = verification.getSignerCertificates();
        for (X509Certificate certificate : activeSigners) {
            add(identities, "active", certificate);
        }

        SigningCertificateLineage lineage = verification.getSigningCertificateLineage();
        if (lineage != null) {
            for (X509Certificate certificate : lineage.getCertificatesInLineage()) {
                add(identities, "history", certificate);
            }
        }

        if (activeSigners.isEmpty() || identities.isEmpty()) {
            System.err.println("verified APK exposes no signer certificate");
            System.exit(1);
        }

        for (Map.Entry<String, Identity> entry : identities.entrySet()) {
            Identity identity = entry.getValue();
            System.out.println(
                    identity.role
                            + "\t"
                            + entry.getKey()
                            + "\t"
                            + sha256(identity.certificate.getPublicKey().getEncoded()));
        }
    }
}
