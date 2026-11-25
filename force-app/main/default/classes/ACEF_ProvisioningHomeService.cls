/**
 * ACE Provisioning (ACE PGA Processing app) homepage metrics. The portal ends after the
 * Security / PSO step; BI adjudication, provisioning and the ACE security review happen in this
 * app. CBPPGA-88: counts use the lifecycle Status (ACEF_PGA_Application__c.ACEF_Status__c), the
 * same field the stage list views filter on, so a tile count matches the list it opens.
 */
public with sharing class ACEF_ProvisioningHomeService {
  public class Tile {
    @AuraEnabled
    public String key;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String help;
    @AuraEnabled
    public Integer count = 0;
    @AuraEnabled
    public String objectApiName;
    @AuraEnabled
    public String listViewName;
  }

  public class Summary {
    @AuraEnabled
    public Integer totalPackages = 0;
    @AuraEnabled
    public List<Tile> tiles = new List<Tile>();
  }

  /** Status tiles, in lifecycle order: label (Status value), list view, help text. */
  @TestVisible
  private static final List<List<String>> STAGES = new List<List<String>>{
    new List<String>{ 'Draft', 'XPGA_Stage_Waiting_Forms', 'Requester, supervisors and Agency Security Officer still completing the package.' },
    new List<String>{ 'Pending BI Review', 'XPGA_Stage_Awaiting_Vetting', 'Full package received (7300 Pending BI Determination); record the BI adjudication.' },
    new List<String>{ 'Ready for Provisioning', 'XPGA_Stage_Ready_Route', 'BI favorable; click Provision.' },
    new List<String>{ 'Provisioned', 'XPGA_Stage_In_Provisioning', 'Provisioned; AES / GCMC teams emailed when requested.' },
    new List<String>{ 'ACE Security Review', 'XPGA_Stage_Awaiting_ACE_Security', 'Complete the ACE security review.' },
    new List<String>{ 'Complete', 'XPGA_Stage_Completed', 'Provisioning and ACE security review complete.' },
    new List<String>{ 'Unfavorable BI Determination', 'XPGA_Stage_Closed_Unfavorable', 'BI adjudication unfavorable; processing stopped.' }
  };

  private static final Set<String> FINISHED = new Set<String>{ 'Complete', 'Unfavorable BI Determination' };

  @AuraEnabled
  public static Summary getSummary() {
    Summary out = new Summary();
    Map<String, Integer> byStage = new Map<String, Integer>();
    Integer assignedToMe = 0;
    Id me = UserInfo.getUserId();
    for (ACEF_PGA_Application__c pkg : [
      SELECT OwnerId, ACEF_Status__c
      FROM ACEF_PGA_Application__c
      LIMIT 5000
    ]) {
      out.totalPackages++;
      String stage = String.isBlank(pkg.ACEF_Status__c) ? 'Draft' : pkg.ACEF_Status__c;
      byStage.put(stage, (byStage.containsKey(stage) ? byStage.get(stage) : 0) + 1);
      if (pkg.OwnerId == me && !FINISHED.contains(stage)) {
        assignedToMe++;
      }
    }

    out.tiles.add(tile('assigned', 'My assigned application packages', 'Open packages you own.', assignedToMe, 'ACEF_PGA_Application__c', 'XPGA_My_Assigned'));
    for (List<String> stage : STAGES) {
      out.tiles.add(
        tile(stage[1], stage[0], stage[2], byStage.containsKey(stage[0]) ? byStage.get(stage[0]) : 0, 'ACEF_PGA_Application__c', stage[1])
      );
    }
    // Form 7300 only requests (no ACE Portal access) have no package but are vetted here too.
    Integer form7300Only = [
      SELECT COUNT()
      FROM ACEF_Form_7300_Request__c
      WHERE
        ACEF_Status__c IN ('Section 4 Complete', 'With 7300 Processing')
        AND ACEF_BI_Disposition__c NOT IN ('Favorable', 'Unfavorable')
        AND ACEF_ACE_Access_Requested__c = false
    ];
    out.tiles.add(
      tile('form7300Only', 'Form 7300 only: awaiting vetting', 'No ACE Portal access requested; record the BI result on the Form 7300.', form7300Only, 'ACEF_Form_7300_Request__c', 'X7300_Awaiting_Vetting')
    );
    return out;
  }

  private static Tile tile(String key, String label, String help, Integer count, String objectApiName, String listViewName) {
    Tile t = new Tile();
    t.key = key;
    t.label = label;
    t.help = help;
    t.count = count;
    t.objectApiName = objectApiName;
    t.listViewName = listViewName;
    return t;
  }
}