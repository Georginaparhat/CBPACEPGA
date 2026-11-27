public with sharing class ACEF_HashIdService {
  public class HashResult {
    public String hashId;
  }

  public static HashResult generateForPackage(Id packageId) {
    String hashId = EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf(String.valueOf(packageId)))
      )
      .left(16);
    if (packageId != null) {
      update new ACEF_PGA_Application__c(Id = packageId, ACEF_Hash_Id__c = hashId);
    }
    HashResult result = new HashResult();
    result.hashId = hashId;
    return result;
  }
}
