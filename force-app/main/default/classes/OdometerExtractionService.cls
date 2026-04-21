public class OdometerExtractionService {

    /**
     * Extracts odometer reading from a base64-encoded image using Salesforce Prompt Builder
     * @param base64Image - Base64 encoded image string (with or without data URL prefix)
     * @return Decimal - Extracted odometer reading, or null if extraction fails
     */
    @AuraEnabled
    public static Decimal extractOdometerReading(String base64Image) {
        try {
            // Clean the base64 string (remove data URL prefix if present)
            String cleanBase64 = base64Image.contains(',')
                ? base64Image.split(',')[1]
                : base64Image;

            // Step 1: Store image as ContentVersion so Prompt Builder can access it as a real file
            ContentVersion cv = new ContentVersion();
            cv.VersionData          = EncodingUtil.base64Decode(cleanBase64);
            cv.Title                = 'Odometer_' + System.now().getTime() + '.jpg';
            cv.PathOnClient         = cv.Title;
            cv.FirstPublishLocationId = UserInfo.getUserId();
            insert cv;

            // Step 2: Get the ContentDocumentId
            ContentVersion insertedCV = [
                SELECT ContentDocumentId
                FROM ContentVersion
                WHERE Id = :cv.Id
                LIMIT 1
            ];
            Id contentDocumentId = insertedCV.ContentDocumentId;

            // Step 3: Invoke Prompt Builder passing ContentDocumentId as record input
            Decimal extractedReading = invokePromptBuilder(contentDocumentId);

            // Step 4: Clean up temporary file
            delete [SELECT Id FROM ContentDocument WHERE Id = :contentDocumentId];

            return extractedReading;

        } catch (Exception e) {
            System.debug('Exception in extractOdometerReading: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error extracting odometer reading: ' + e.getMessage());
        }
    }

    /**
     * Invokes the Prompt Builder Flex Template.
     * The template input variable 'imageId' must be of Type = "Record", Object = ContentDocument
     * so Prompt Builder can actually load and vision-analyze the image file.
     * @param contentDocumentId - ID of the stored ContentDocument
     * @return Decimal - Extracted odometer reading
     */
    private static Decimal invokePromptBuilder(Id contentDocumentId) {
        try {
            Map<String, ConnectApi.WrappedValue> inputParams =
                new Map<String, ConnectApi.WrappedValue>();

            // IMPORTANT: Pass the ID inside a Map with key 'id'
            // This is how Prompt Builder resolves a Record-type input
            Map<String, String> recordInput = new Map<String, String>();
            recordInput.put('id', (String) contentDocumentId);

            ConnectApi.WrappedValue imageValue = new ConnectApi.WrappedValue();
            imageValue.value = recordInput;
            inputParams.put('Input:imageId2', imageValue);

            // Configure generation input
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.inputParams   = inputParams;
            input.isPreview     = false;

            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.numGenerations  = 1;
            input.additionalConfig.enablePiiMasking = false;
            input.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';

            // Invoke Prompt Builder template
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    'Odometer_Reading_Extractor',
                    input
                );

            if (response != null && response.generations != null &&
                !response.generations.isEmpty()) {

                String generatedText = response.generations[0].text;
                System.debug('Prompt Builder Response: ' + generatedText);
                return parseOdometerReading(generatedText);
            } else {
                throw new AuraHandledException('No response from Prompt Builder');
            }

        } catch (Exception e) {
            System.debug('Error invoking Prompt Builder: ' + e.getMessage());
            throw new AuraHandledException('Failed to extract odometer reading: ' + e.getMessage());
        }
    }

    /**
     * Parses the odometer reading from Prompt Builder response
     * Expected formats:
     * - "12345" (just the number)
     * - "The odometer reading is 12345"
     * - JSON: {"reading": 12345, "confidence": "high"}
     */
    private static Decimal parseOdometerReading(String response) {
        try {
            // Try to parse as JSON first
            if (response.trim().startsWith('{')) {
                Map<String, Object> jsonResponse =
                    (Map<String, Object>) JSON.deserializeUntyped(response);

                if (jsonResponse.containsKey('reading')) {
                    Object readingObj = jsonResponse.get('reading');
                    return convertToDecimal(readingObj);
                }
            }

            // Extract numbers from text response
            Pattern numberPattern = Pattern.compile('\\d+');
            Matcher matcher = numberPattern.matcher(response);

            List<String> numbers = new List<String>();
            while (matcher.find()) {
                numbers.add(matcher.group());
            }

            if (!numbers.isEmpty()) {
                Decimal maxNumber = 0;
                for (String num : numbers) {
                    Decimal currentNum = Decimal.valueOf(num);
                    if (currentNum > maxNumber) {
                        maxNumber = currentNum;
                    }
                }
                return maxNumber;
            }

            throw new AuraHandledException('Could not parse odometer reading from response');

        } catch (Exception e) {
            System.debug('Error parsing odometer reading: ' + e.getMessage());
            throw new AuraHandledException('Failed to parse odometer reading');
        }
    }

    /**
     * Converts various object types to Decimal
     */
    private static Decimal convertToDecimal(Object value) {
        if (value instanceof Integer) {
            return (Decimal) value;
        } else if (value instanceof Long) {
            return (Decimal) ((Long) value);
        } else if (value instanceof Decimal) {
            return (Decimal) value;
        } else if (value instanceof String) {
            return Decimal.valueOf((String) value);
        }
        return null;
    }

    /**
     * Invocable method for Flow-based invocation
     */
    @InvocableMethod(label='Extract Odometer Reading'
                     description='Extracts odometer reading from image using Prompt Builder'
                     category='AI')
    public static List<OdometerResult> extractOdometerFromFlow(List<OdometerRequest> requests) {
        List<OdometerResult> results = new List<OdometerResult>();

        for (OdometerRequest request : requests) {
            OdometerResult result = new OdometerResult();
            try {
                result.reading = extractOdometerReading(request.base64Image);
                result.success = true;
                result.message = 'Successfully extracted odometer reading';
            } catch (Exception e) {
                result.success = false;
                result.message = e.getMessage();
            }
            results.add(result);
        }

        return results;
    }

    public class OdometerRequest {
        @InvocableVariable(required=true label='Base64 Image')
        public String base64Image;
    }

    public class OdometerResult {
        @InvocableVariable(label='Odometer Reading')
        public Decimal reading;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Message')
        public String message;
    }
}