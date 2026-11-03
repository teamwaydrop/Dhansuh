import java.io.*;
import java.util.*;
import java.util.jar.*;
import java.security.*;
import java.security.cert.X509Certificate;

// Read-only JAR/AAB verification. Never opens a keystore or prints private data.
class InspectBundleSignature {
  public static void main(String[] args) throws Exception {
    Set<String> hashes = new TreeSet<>();
    int signed = 0;
    try (JarFile jar = new JarFile(args[0], true)) {
      for (JarEntry entry : Collections.list(jar.entries())) {
        if (entry.isDirectory() || entry.getName().startsWith("META-INF/")) continue;
        try (InputStream stream = jar.getInputStream(entry)) { stream.transferTo(OutputStream.nullOutputStream()); }
        CodeSigner[] signers = entry.getCodeSigners();
        if (signers == null || signers.length != 1) throw new SecurityException("Unsigned or unexpected multi-signer bundle entry");
        X509Certificate certificate = (X509Certificate) signers[0].getSignerCertPath().getCertificates().get(0);
        certificate.checkValidity();
        hashes.add(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded())));
        signed++;
      }
    }
    if (hashes.size() != 1 || signed == 0) throw new SecurityException("Inconsistent bundle signing");
    System.out.println("{\"signature_verified\":true,\"signed_entries\":"+signed+",\"signer_sha256\":\""+hashes.iterator().next()+"\"}");
  }
}
