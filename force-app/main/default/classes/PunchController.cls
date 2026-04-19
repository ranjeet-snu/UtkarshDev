public class PunchController {

    public class PunchStateDTO {
        @AuraEnabled public Id employeeId;
        @AuraEnabled public Id userId;
        @AuraEnabled public String employeeName;
        @AuraEnabled public String currentStatus;     // IN / OUT
        @AuraEnabled public Datetime lastPunchTime;
        @AuraEnabled public String lastAction;        // IN / OUT
        @AuraEnabled public Decimal lastLat;
        @AuraEnabled public Decimal lastLng;
        @AuraEnabled public Decimal lastBattery;
        @AuraEnabled public String status;
        @AuraEnabled public String lastOdometerUrl;
        @AuraEnabled public String lastPunchType;
        @AuraEnabled public Boolean isWFHApprovedForToday; 
        @AuraEnabled public Boolean isWFOApproved;
        @AuraEnabled public String wfhRequestStatusTomorrow;
        @AuraEnabled public Time wfhStartTime;
        @AuraEnabled public Time wfhEndTime;
        @AuraEnabled public Date requestedDate;

    }

    // ─────────────────────────────────────────────────────────────────────────
    // LEGACY: Employee__c-based methods (kept for backward compatibility)
    // ─────────────────────────────────────────────────────────────────────────

    @AuraEnabled
    public static PunchStateDTO getCurrentState(Id employeeId) {
        PunchStateDTO dto = new PunchStateDTO();
        dto.employeeId = employeeId;

        Employee__c emp = [
            SELECT Id, Name, Current_Status__c, Last_Punch_Time__c,
                   Latitude__c, Longitude__c, Battery_Percentage__c
            FROM Employee__c
            WHERE Id = :employeeId
        ];

        dto.employeeName  = emp.Name;
        dto.currentStatus = String.valueOf(emp.Current_Status__c);
        dto.lastPunchTime = emp.Last_Punch_Time__c;
        dto.lastLat       = emp.Latitude__c;
        dto.lastLng       = emp.Longitude__c;
        dto.lastBattery   = emp.Battery_Percentage__c;

        Punch_Record__c lastPunch = null;
        try {
            lastPunch = [
                SELECT Id, Action__c, Status__c, Punch_Time__c, Latitude__c, Longitude__c, Battery__c, Punch_Type__c
                FROM Punch_Record__c
                WHERE Employee__c = :employeeId
                ORDER BY Punch_Time__c DESC
                LIMIT 1
            ];
        } catch (Exception e) {
            // ignore if none
        }

        if (lastPunch != null) {
            dto.lastAction    = String.valueOf(lastPunch.Action__c);
            dto.lastPunchTime = lastPunch.Punch_Time__c;
            dto.lastLat       = lastPunch.Latitude__c;
            dto.lastLng       = lastPunch.Longitude__c;
            dto.lastBattery   = lastPunch.Battery__c;
            dto.currentStatus = String.valueOf(lastPunch.Status__c);
            dto.lastPunchType = lastPunch.Punch_Type__c;
        }

        return dto;
    }

    @AuraEnabled
    public static PunchStateDTO punchNow(Id employeeId, Decimal latitude, Decimal longitude,
                                         Decimal battery, String odometerImageBase64, String fileName) {
        Employee__c emp = [
            SELECT Id, Current_Status__c
            FROM Employee__c
            WHERE Id = :employeeId
        ];

        Boolean isPunchingIn = emp.Current_Status__c != 'IN';

        Punch_Record__c p = new Punch_Record__c();
        p.Employee__c   = employeeId;
        p.Action__c     = isPunchingIn ? 'IN' : 'OUT';
        p.Status__c     = isPunchingIn ? 'IN' : 'OUT';
        p.Punch_Time__c = System.now();
        p.Latitude__c   = latitude;
        p.Longitude__c  = longitude;
        p.Battery__c    = battery;
        insert p;

        if (odometerImageBase64 != null) {
            ContentVersion cv = new ContentVersion();
            String base64Data = odometerImageBase64.contains(',') ? odometerImageBase64.split(',')[1] : odometerImageBase64;
            cv.VersionData            = EncodingUtil.base64Decode(base64Data);
            cv.Title                  = fileName;
            cv.PathOnClient           = fileName;
            cv.FirstPublishLocationId = p.Id;
            insert cv;
        }

        emp.Current_Status__c     = isPunchingIn ? 'IN' : 'OUT';
        emp.Last_Punch_Time__c    = p.Punch_Time__c;
        emp.Latitude__c           = latitude;
        emp.Longitude__c          = longitude;
        emp.Battery_Percentage__c = battery;
        update emp;

        return getCurrentState(employeeId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEW: User-based methods via intermediate User_Punch_State__c object
    // Identity is resolved from UserInfo.getUserId() — no param required
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns the current punch state for the logged-in User.
     * Reads from User_Punch_State__c (one record per User) and the latest
     * Punch_Record__c for that User.
     */
    @AuraEnabled
    public static PunchStateDTO getCurrentStateForUser() {
        Id runningUserId = UserInfo.getUserId();
        PunchStateDTO dto = new PunchStateDTO();
        dto.userId = runningUserId;
        dto.employeeName = UserInfo.getName();

        // Try to find the state record for this user
        List<User_Punch_State__c> stateList = [
            SELECT Id, Current_Status__c, Last_Punch_Time__c,
                   Latitude__c, Longitude__c, Battery_Percentage__c
            FROM User_Punch_State__c
            WHERE User__c = :runningUserId
            LIMIT 1
        ];

        if (!stateList.isEmpty()) {
            User_Punch_State__c state = stateList[0];
            dto.currentStatus = String.isBlank(state.Current_Status__c) ? 'OUT' : state.Current_Status__c;
            dto.lastPunchTime = state.Last_Punch_Time__c;
            dto.lastLat       = state.Latitude__c;
            dto.lastLng       = state.Longitude__c;
            dto.lastBattery   = state.Battery_Percentage__c;
        } else {
            dto.currentStatus = 'OUT';
        }

        // Get the most recent punch record for this user
        List<Punch_Record__c> lastPunches = [
            SELECT Id, Action__c, Status__c, Punch_Time__c, Latitude__c, Longitude__c, Battery__c, Punch_Type__c
            FROM Punch_Record__c
            WHERE User__c = :runningUserId AND Is_WFH_Request__c = false AND Is_WFO_Request__c = false
            ORDER BY Punch_Time__c DESC, Id DESC
            LIMIT 1
        ];

        if (!lastPunches.isEmpty()) {
            Punch_Record__c lp = lastPunches[0];
            dto.lastAction    = String.valueOf(lp.Action__c);
            dto.lastPunchTime = lp.Punch_Time__c;
            dto.lastLat       = lp.Latitude__c;
            dto.lastLng       = lp.Longitude__c;
            dto.lastBattery   = lp.Battery__c;
            dto.currentStatus = String.valueOf(lp.Status__c);
            dto.lastPunchType = lp.Punch_Type__c;

            // Fetch attached odometer image
            List<ContentDocumentLink> cdls = [
                SELECT ContentDocumentId 
                FROM ContentDocumentLink 
                WHERE LinkedEntityId = :lp.Id 
                LIMIT 1
            ];
            
            if (!cdls.isEmpty()) {
                List<ContentVersion> cvs = [
                    SELECT Id 
                    FROM ContentVersion 
                    WHERE ContentDocumentId = :cdls[0].ContentDocumentId AND IsLatest = true 
                    LIMIT 1
                ];
                if (!cvs.isEmpty()) {
                    dto.lastOdometerUrl = '/sfc/servlet.shepherd/version/download/' + cvs[0].Id;
                }
            }
        }

        // --- WFH Approval Check ---
        Date todayVal = Date.today();
        // Date tomorrowVal = todayVal.addDays(1);

        // Check for approved WFH today
        List<Punch_Record__c> approvedToday = [
            SELECT Id, Is_WFH_Request__c, Is_WFO_Request__c, WFH_Request_Date__c, 
                WFH_Request_Start_Time__c, WFH_Request_End_Time__c, WFH_Approval_Status__c
            FROM Punch_Record__c 
            WHERE User__c = :runningUserId 
            AND (Is_WFH_Request__c = true OR Is_WFO_Request__c = true)
            AND WFH_Request_Date__c >= :todayVal 
            AND WFH_Approval_Status__c != 'Rejected'
            ORDER BY WFH_Request_Date__c DESC, CreatedDate DESC
            LIMIT 1
        ];
        if (!approvedToday.isEmpty()) {
            dto.isWFHApprovedForToday = approvedToday[0].Is_WFH_Request__c;
            dto.isWFOApproved = approvedToday[0].Is_WFO_Request__c;
            dto.requestedDate = approvedToday[0].WFH_Request_Date__c;
            dto.wfhStartTime = approvedToday[0].WFH_Request_Start_Time__c;
            dto.wfhEndTime = approvedToday[0].WFH_Request_End_Time__c;
            dto.wfhRequestStatusTomorrow = approvedToday[0].WFH_Approval_Status__c;
        } else {
            dto.isWFHApprovedForToday = false;
            dto.isWFOApproved = false;
            dto.wfhRequestStatusTomorrow = 'Rejected';
        }

        // Check for request status tomorrow
        // List<Punch_Record__c> reqTomorrow = [
        //     SELECT WFH_Approval_Status__c 
        //     FROM Punch_Record__c 
        //     WHERE User__c = :runningUserId 
        //     AND (Is_WFH_Request__c = true OR Is_WFO_Request__c = true)
        //     AND WFH_Request_Date__c = :tomorrowVal 
        //     ORDER BY CreatedDate DESC 
        //     LIMIT 1
        // ];
        // if (!reqTomorrow.isEmpty()) {
        //     dto.wfhRequestStatusTomorrow = reqTomorrow[0].WFH_Approval_Status__c;
        // } else {
        //     dto.wfhRequestStatusTomorrow = 'Not Requested';
        // }

        return dto;
    }

    /**
     * Creates a Punch_Record__c linked to the running User,
     * then upserts the User_Punch_State__c record to reflect the new status.
     */
    @AuraEnabled
    public static PunchStateDTO punchNowAsUser(Decimal latitude, Decimal longitude,
                                               Decimal battery, String selfieImageBase64,
                                               String odometerImageBase64,
                                               String fileName, String punchType, 
                                               String wfhActivity, String transportType, 
                                               String vehicleType, Decimal odometerReading,
                                               Decimal extractedOdometer) {
        Id runningUserId = UserInfo.getUserId();

        // Determine current status from state record
        String currentStatus = 'OUT';
        Id stateRecordId = null;

        List<User_Punch_State__c> stateList = [
            SELECT Id, Current_Status__c
            FROM User_Punch_State__c
            WHERE User__c = :runningUserId
            LIMIT 1
        ];

        if (!stateList.isEmpty()) {
            currentStatus = String.isBlank(stateList[0].Current_Status__c)
                ? 'OUT'
                : stateList[0].Current_Status__c;
            stateRecordId = stateList[0].Id;
        }

        Boolean isPunchingIn = currentStatus != 'IN';
        String newStatus = isPunchingIn ? 'IN' : 'OUT';
        Datetime punchTime = System.now();

        // Create the Punch_Record__c
        Punch_Record__c p = new Punch_Record__c();
        p.User__c       = runningUserId;
        p.Action__c     = newStatus;
        p.Status__c     = newStatus;
        p.Punch_Time__c = punchTime;
        p.Latitude__c   = latitude;
        p.Longitude__c  = longitude;
        p.Battery__c    = battery;
        
        // New Fields
        p.Punch_Type__c           = punchType;
        p.WFH_Activity__c         = wfhActivity;
        p.Transportation_Type__c   = transportType;
        p.Vehicle_Type__c         = vehicleType;
        p.Odometer_Reading__c     = odometerReading;
        p.Extracted_Odometer_Reading__c = extractedOdometer;

        // WFH Approval Logic
        if (isPunchingIn && punchType == 'WFH') {
            List<Punch_Record__c> approvedReq = [
                SELECT Id 
                FROM Punch_Record__c 
                WHERE User__c = :runningUserId 
                AND Is_WFH_Request__c = true 
                AND WFH_Request_Date__c = TODAY 
                AND WFH_Approval_Status__c = 'Approved'
                LIMIT 1
            ];
            if (approvedReq.isEmpty()) {
                throw new AuraHandledException('WFH punch is only allowed if a request for today has been approved by your manager.');
            }
            p.WFH_Approval_Status__c = 'Approved';
        }

        insert p;

        // Attach selfie image if provided
        if (String.isNotBlank(selfieImageBase64)) {
            ContentVersion cv = new ContentVersion();
            String base64Data = selfieImageBase64.contains(',')
                ? selfieImageBase64.split(',')[1]
                : selfieImageBase64;
            cv.VersionData            = EncodingUtil.base64Decode(base64Data);
            cv.Title                  = 'selfie_capture.jpg';
            cv.PathOnClient           = 'selfie_capture.jpg';
            cv.FirstPublishLocationId = p.Id;
            insert cv;
        }

        // Attach odometer image if provided
        if (String.isNotBlank(odometerImageBase64)) {
            ContentVersion cv = new ContentVersion();
            String base64Data = odometerImageBase64.contains(',')
                ? odometerImageBase64.split(',')[1]
                : odometerImageBase64;
            cv.VersionData            = EncodingUtil.base64Decode(base64Data);
            cv.Title                  = 'odometer_capture.jpg';
            cv.PathOnClient           = 'odometer_capture.jpg';
            cv.FirstPublishLocationId = p.Id;
            insert cv;
        }

        // Upsert the User_Punch_State__c record (one per user)
        User_Punch_State__c stateRecord = new User_Punch_State__c();
        if (stateRecordId != null) {
            stateRecord.Id = stateRecordId;
        }
        stateRecord.User__c               = runningUserId;
        stateRecord.Current_Status__c     = newStatus;
        stateRecord.Last_Punch_Time__c    = punchTime;
        stateRecord.Latitude__c           = latitude;
        stateRecord.Longitude__c          = longitude;
        stateRecord.Battery_Percentage__c = battery;
        upsert stateRecord;

        return getCurrentStateForUser();
    }

    /**
     * Submits a WFH request for a specific date and time range.
     */
    @AuraEnabled
    public static void submitWFHRequest(Date reqDate, String startTimeStr, String endTimeStr, string catagory) {
        Id runningUserId = UserInfo.getUserId();
        
        Punch_Record__c p = new Punch_Record__c();
        p.User__c = runningUserId;
        // p.Is_WFH_Request__c = true;
        p.Punch_Type__c = catagory;
        if(catagory == 'WFH'){
            p.Is_WFH_Request__c = true;
        }else{
            p.Is_WFH_Request__c = false;
        }
        if(catagory == 'WFO'){
            p.Is_WFO_Request__c = true;
        }else{
            p.Is_WFO_Request__c = false;
        }
        p.WFH_Request_Date__c = reqDate;
        p.WFH_Approval_Status__c = 'Pending';
        
        // Set Approver from Custom Metadata
        List<Manager_Assignment__mdt> mapping = [
            SELECT Manager_User_Id__c 
            FROM Manager_Assignment__mdt 
            WHERE Target_User_Id__c = :runningUserId 
            LIMIT 1
        ];
        if (!mapping.isEmpty()) {
            p.WFH_Approver__c = (Id)mapping[0].Manager_User_Id__c;
        }

        if (String.isNotBlank(startTimeStr)) {
            p.WFH_Request_Start_Time__c = parseTime(startTimeStr);
        }
        if (String.isNotBlank(endTimeStr)) {
            p.WFH_Request_End_Time__c = parseTime(endTimeStr);
        }

        insert p;
    }

    private static Time parseTime(String timeStr) {
        // Expected format: "HH:mm:ss.SSS" or "HH:mm"
        try {
            List<String> parts = timeStr.split(':');
            Integer h = Integer.valueOf(parts[0]);
            Integer m = Integer.valueOf(parts[1]);
            Integer s = 0;
            if (parts.size() > 2) {
                // If there's seconds, it might have milliseconds too
                String secPart = parts[2];
                if (secPart.contains('.')) {
                    s = Integer.valueOf(secPart.split('\\.')[0]);
                } else {
                    s = Integer.valueOf(secPart);
                }
            }
            return Time.newInstance(h, m, s, 0);
        } catch (Exception e) {
            return null;
        }
    }

    @AuraEnabled
    public static String saveSelfieForAccount(Id accountId, String base64Photo, Decimal userLat, Decimal userLon) {
        try {
            // Save as ContentVersion
            ContentVersion cv = new ContentVersion();
            String base64Data = base64Photo.contains(',') ? base64Photo.split(',')[1] : base64Photo;
            cv.VersionData = EncodingUtil.base64Decode(base64Data);
            cv.Title = 'Selfie_' + System.now().format('yyyyMMdd_HHmmss') + '.jpg';
            cv.PathOnClient = cv.Title;
            cv.FirstPublishLocationId = accountId;
            insert cv;

            // Update location on the record (assuming it's Employee__c based on usage)
            if (accountId.getSObjectType() == Employee__c.SObjectType) {
                Employee__c emp = new Employee__c(Id = accountId);
                emp.Latitude__c = userLat;
                emp.Longitude__c = userLon;
                emp.Last_Punch_Time__c = System.now();
                update emp;
            }

            return [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].Id;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}