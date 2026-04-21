import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCurrentStateForUser from '@salesforce/apex/PunchController.getCurrentStateForUser';
import punchNowAsUser from '@salesforce/apex/PunchController.punchNowAsUser';
import submitWFHRequest from '@salesforce/apex/PunchController.submitWFHRequest';
import extractOdometerReading from '@salesforce/apex/OdometerExtractionService.extractOdometerReading';

export default class UserPunch extends LightningElement {

    // ── State ──────────────────────────────────────────────────────────────
    @track loading      = true;
    @track stateLoaded  = false;
    @track isPunching   = false;
    @track error;

    @track employeeName;
    @track userId;
    @track currentStatus; // 'IN' | 'OUT'
    @track lastPunchTime;
    @track lastBattery;
    @track lastOdometerUrl;
    @track lastPunchType;
    @track lastLat;
    @track lastLng;

    @track punchType = '';
    @track wfhActivity = '';
    @track transportType = ''; // 'Public', 'Private'
    @track vehicleType = ''; // 'Two', 'Four'
    @track odometerReading = '';
    @track extractedOdometer = '';

    @track selfiePreview = '';
    @track odometerPreview = '';
    @track videoInitialized = false;
    @track showImageModal = false;

    // AI Extraction State
    @track isExtractingOdometer = false;

    // WFH Request
    @track isWFHApprovedForToday = false;
    @track isWFOApproved = false;
    @track requestedDate = null;
    @track wfhStartTime = null;
    @track wfhEndTime = null;
    @track wfhRequestStatusTomorrow = '';
    @track wfhReqStart = '09:00:00.000';
    @track wfhReqEnd = '18:00:00.000';
    @track varReqDate = new Date().toISOString().split('T')[0]; 
    @track isSubmittingReq = false;
    @track selectedValue = 'WFO';

    picklistValues = [
        { label: 'WFO', value: 'WFO' },
        { label: 'WFH', value: 'WFH' },
    ];

    handleChange(event) {
        this.selectedValue = event.detail.value;
    }

    selfieStream;
    odoStream;

    // ── Lifecycle ──────────────────────────────────────────────────────────
    connectedCallback() {
        this.loadState();
    }

    disconnectedCallback() {
        this.stopStreams();
    }

    renderedCallback() {
        if (!this.videoInitialized) {
            this.initCameras();
        }
    }

    // ── Data load ──────────────────────────────────────────────────────────
    loadState() {
        this.loading = true;
        this.error   = undefined;

        getCurrentStateForUser()
            .then((data) => {
                if (data) {
                    this.employeeName    = data.employeeName;
                    this.userId          = data.userId;
                    this.currentStatus   = data.currentStatus || 'OUT';
                    this.lastPunchTime   = data.lastPunchTime;
                    this.lastBattery     = data.lastBattery;
                    this.lastOdometerUrl = data.lastOdometerUrl;
                    this.lastPunchType   = data.lastPunchType;
                    this.lastLat         = data.lastLat;
                    this.lastLng         = data.lastLng;
                    
                    this.isWFHApprovedForToday = data.isWFHApprovedForToday;
                    this.isWFOApproved   = data.isWFOApproved;
                    this.requestedDate   = data.requestedDate;
                    this.wfhStartTime    = data.wfhStartTime;
                    this.wfhEndTime      = data.wfhEndTime;
                    this.wfhRequestStatusTomorrow = data.wfhRequestStatusTomorrow;

                    this.stateLoaded     = true;

                    // No default punch type
                    this.punchType = '';
                }
                console.log('UserPunch - loadState data', JSON.stringify(data));
                console.log('UserPunch - loadState data', JSON.stringify(data.currentStatus));
                this.loading = false;
            })
            .catch((err) => {
                console.error('UserPunch - loadState error', err);
                this.error   = 'Failed to load your punch status.';
                this.loading = false;
            });
    }

    // ── Image Modal ────────────────────────────────────────────────────────
    openImageModal() {
        this.showImageModal = true;
    }

    closeImageModal() {
        this.showImageModal = false;
    }

    // ── Category Handlers ──────────────────────────────────────────────────
    selectWFO() { this.punchType = 'WFO'; }
    selectWFH() { this.punchType = 'WFH'; }
    selectMarketVisit() { this.punchType = 'Market Visit'; }

    handleWFHActivityChange(event) {
        this.wfhActivity = event.target.value;
    }

    selectPublicTransport() { this.transportType = 'Public Transport'; }
    selectPrivateVehicle() { 
        this.transportType = 'Private Vehicle'; 
        // Small delay to ensure video element is rendered
        setTimeout(() => this.initCameras(), 100);
    }

    selectTwoWheeler() { this.vehicleType = 'Two Wheeler'; }
    selectFourWheeler() { this.vehicleType = 'Four Wheeler'; }

    handleOdometerChange(event) {
        this.odometerReading = event.target.value;
    }

    // WFH Request Handlers
    handleReqDateChange(event) { 
        this.varReqDate = event.target.value;
     }
    handleWfhReqStartChange(event) { 
        this.wfhReqStart = event.target.value; 
    }
    handleWfhReqEndChange(event) { 
        this.wfhReqEnd = event.target.value; 
    }

    validateAllFields() {
        let isValid = true;

        const today = new Date();
        const todayStr = today.toISOString().split('T')[0];

        // Past Date Validation
        if (this.varReqDate && this.varReqDate < todayStr) {
            this.showToast('Error', 'Past date selection is not allowed', 'error');
            isValid = false;
        }

        // Required validation
        if (!this.varReqDate) {
            isValid = false;
        }

        if (!this.wfhReqStart) {
            isValid = false;
        }

        if (!this.wfhReqEnd) {
            isValid = false;
        }

        // Past Time Validation (only for today)
        if (this.varReqDate === todayStr && this.wfhReqStart) {
            const now = new Date();
            const currentMinutes = now.getHours() * 60 + now.getMinutes();

            const [h, m] = this.wfhReqStart.split(':').map(Number);
            const selectedMinutes = h * 60 + m;

            if (selectedMinutes < currentMinutes) {
                this.showToast('Error', 'Start time cannot be in the past', 'error');
                isValid = false;
            }
        }

        // End > Start Validation
        if (this.wfhReqStart && this.wfhReqEnd) {
            const [sh, sm] = this.wfhReqStart.split(':').map(Number);
            const [eh, em] = this.wfhReqEnd.split(':').map(Number);

            const startMin = sh * 60 + sm;
            const endMin = eh * 60 + em;

            if (endMin <= startMin) {
                this.showToast('Error', 'End time must be after start time', 'error');
                isValid = false;
            }
        }

        return isValid;
    }

    handleWfhRequestSubmit() {
        if (!this.wfhReqStart || !this.wfhReqEnd) {
            this.showToast('Validation Error', 'Please provide both start and end times.', 'error');
            return;
        }
        console.log('Hit');
        const isValid = this.validateAllFields();
        console.log('Hit2');

        if (!isValid) {
            console.log('Hit3');
            return;
        }

        this.isSubmittingReq = true;

        submitWFHRequest({
            reqDate: this.varReqDate,
            startTimeStr: this.wfhReqStart,
            endTimeStr: this.wfhReqEnd,
            catagory : this.selectedValue,
        })
        .then(() => {
            this.showToast('Success', 'WFH Request for tomorrow submitted successfully.', 'success');
            return this.loadState(); // Refresh status
        })
        .catch(err => {
            console.error('Error submitting WFH request', err);
            this.showToast('Error', 'Failed to submit WFH request.', 'error');
        })
        .finally(() => {
            this.isSubmittingReq = false;
        });
    }

    // ── Computed properties ────────────────────────────────────────────────
    get isPunchedIn() {
        return this.currentStatus === 'IN';
    }

    get isWFH() { return this.punchType === 'WFH'; }
    get isMarketVisit() { return this.punchType === 'Market Visit'; }
    get isPrivateVehicle() { return this.isMarketVisit && this.transportType === 'Private Vehicle'; }

    get buttonLabel() {
        return this.isPunchedIn ? 'Punch Out' : 'Punch In';
    }

    get punchBtnIcon() {
        return this.isPunchedIn ? 'utility:logout' : 'utility:login';
    }

    get punchBtnClass() {
        return 'up-punch-btn ' + (this.isPunchedIn ? 'up-punch-out' : 'up-punch-in');
    }

    get statusLabel() {
        return this.isPunchedIn ? 'PUNCHED IN' : 'PUNCHED OUT';
    }

    get statusBadgeClass() {
        return 'up-badge ' + (this.isPunchedIn ? 'up-badge-in' : 'up-badge-out');
    }

    get statusRingClass() {
        return this.isPunchedIn ? 'up-ring-in' : 'up-ring-out';
    }

    // Class getters for selection UI
    get wfoClass() { return 'up-cat-btn ' + (this.punchType === 'WFO' ? 'up-cat-active' : ''); }
    get wfhClass() { return 'up-cat-btn ' + (this.punchType === 'WFH' ? 'up-cat-active' : ''); }
    get marketVisitClass() { return 'up-cat-btn ' + (this.punchType === 'Market Visit' ? 'up-cat-active' : ''); }

    get publicTransportClass() { return 'up-trans-btn ' + (this.transportType === 'Public Transport' ? 'up-trans-active' : ''); }
    get privateVehicleClass() { return 'up-trans-btn ' + (this.transportType === 'Private Vehicle' ? 'up-trans-active' : ''); }

    get twoWheelerClass() { return 'up-veh-btn ' + (this.vehicleType === 'Two Wheeler' ? 'up-veh-active' : ''); }
    get fourWheelerClass() { return 'up-veh-btn ' + (this.vehicleType === 'Four Wheeler' ? 'up-veh-active' : ''); }

    get wfhActivityLength() { return this.wfhActivity ? this.wfhActivity.length : 0; }
    get charCountClass() { return 'up-char-count ' + (this.wfhActivityLength >= 50 ? 'up-count-ok' : 'up-count-low'); }

    get captureStepLabel() {
        return this.isPrivateVehicle ? '(Steps 1 & 2)' : '(Process)';
    }

    get captureGridClass() {
        return 'up-capture-grid ' + (this.isPrivateVehicle ? 'up-dual-grid' : 'up-single-grid');
    }

    get lastPunchDisplay() {
        if (!this.lastPunchTime) return '';
        try {
            return new Date(this.lastPunchTime).toLocaleString('en-IN', {
                dateStyle: 'medium',
                timeStyle: 'short'
            });
        } catch (e) {
            return this.lastPunchTime;
        }
    }

    get lastLocationDisplay() {
        if (this.lastLat != null && this.lastLng != null) {
            const latNum = Number(this.lastLat);
            const lngNum = Number(this.lastLng);
            
            if (!isNaN(latNum) && !isNaN(lngNum)) {
                return `${latNum.toFixed(4)}, ${lngNum.toFixed(4)}`;
            }
        }
        return '';
    }

    get lastBatteryDisplay() {
        return this.lastBattery ? Math.round(this.lastBattery) : null;
    }

    get showWFHRequestForm() {
        return this.wfhRequestStatusTomorrow && this.wfhRequestStatusTomorrow === 'Rejected' && this.punchType !== 'Market Visit';
    }

    get hasWFHRequestTomorrow() {
        return this.wfhRequestStatusTomorrow && (this.wfhRequestStatusTomorrow === 'Pending' || this.wfhRequestStatusTomorrow === 'Approved');
    }

    get isWFHRequestApprovedTomorrow() {
        return this.wfhRequestStatusTomorrow === 'Approved';
    }

    get isWFHTimely() {
        if (!this.isWFHApprovedForToday || !this.wfhStartTime || !this.wfhEndTime) return false;
        
        const now = new Date();
        const currentMillis = (now.getHours() * 3600000) + (now.getMinutes() * 60000) + (now.getSeconds() * 1000) + now.getMilliseconds();
        
        const start = this.parseTime(this.wfhStartTime);
        const end   = this.parseTime(this.wfhEndTime);
        
        return currentMillis >= start && currentMillis <= end;
    }

    get wfhButtonDisabled() {
        return !this.isWFHApprovedForToday || !this.isWFHTimely;
    }

    get wfhButtonTitle() {
        if (!this.isWFHApprovedForToday) return 'WFH is only available if approved for today.';
        if (!this.isWFHTimely) return `WFH is only available between ${this.formatTime(this.wfhStartTime)} and ${this.formatTime(this.wfhEndTime)}.`;
        return 'Punch in as WFH';
    }

    parseTime(val) {
        if (typeof val === 'number') return val;
        if (typeof val === 'string') {
            const parts = val.split(':');
            if (parts.length >= 2) {
                return (parseInt(parts[0], 10) * 3600000) + (parseInt(parts[1], 10) * 60000);
            }
        }
        return 0;
    }

    formatTime(val) {
        if (val == null) return '';
        if (typeof val === 'string') return val.substring(0, 5);
        
        const date = new Date(val);
        const h = date.getUTCHours().toString().padStart(2, '0');
        const m = date.getUTCMinutes().toString().padStart(2, '0');
        return `${h}:${m}`;
    }

    // ── Punch handler ──────────────────────────────────────────────────────
    handlePunch() {
        // Validations
        if (!this.isPunchedIn) {
            if (!this.punchType) {
                this.showToast('Action Required', 'Please select a punch category (WFO, WFH, or Market Visit).', 'error');
                return;
            }
            if (!this.selfiePreview) {
                this.showToast('Action Required', 'Please capture a selfie before punching.', 'error');
                return;
            }
            if (this.isWFH && this.wfhActivityLength < 50) {
                this.showToast('Validation Error', 'WFH activity note must be at least 50 characters.', 'error');
                return;
            }
            if (this.isMarketVisit && !this.transportType) {
                this.showToast('Validation Error', 'Please select a transportation type.', 'error');
                return;
            }
            if (this.isPrivateVehicle) {
                if (!this.vehicleType) {
                    this.showToast('Validation Error', 'Please select a vehicle type.', 'error');
                    return;
                }
                if (!this.odometerPreview) {
                    this.showToast('Action Required', 'Please capture an odometer reading before punching.', 'error');
                    return;
                }
                if (!this.extractedOdometer) {
                    this.showToast('Action Required', 'Please wait for odometer extraction to complete.', 'error');
                    return;
                }
            }
        }

        if (!navigator.geolocation) {
            this.showToast('Error', 'Geolocation is not supported on this device.', 'error');
            return;
        }

        this.isPunching = true;
        this.error      = undefined;

        navigator.geolocation.getCurrentPosition(
            (pos) => {
                const lat = pos.coords.latitude;
                const lng = pos.coords.longitude;

                this.fetchBattery()
                    .then((battery) => {
                        this.callPunchNow(lat, lng, battery);
                    })
                    .catch(() => {
                        this.callPunchNow(lat, lng, null);
                    });
            },
            (err) => {
                console.error('Geolocation error', err);
                this.isPunching = false;
                
                let errorMsg = 'Unable to get device location. Please allow location access.';
                if (err.code === 1) {
                    errorMsg = 'Location permission denied. Please enable location services in your browser or device settings.';
                } else if (err.code === 2) {
                    errorMsg = 'Location unavailable. Ensure your GPS is turned on.';
                } else if (err.code === 3) {
                    errorMsg = 'Location request timed out. Please try again.';
                }
                
                this.error = errorMsg;
                this.showToast('Location Error', errorMsg, 'error');
            },
            { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 }
        );
    }

    fetchBattery() {
        if (navigator.getBattery) {
            return navigator.getBattery().then((b) => b.level * 100);
        }
        return Promise.resolve(null);
    }

    callPunchNow(lat, lng, battery) {
        punchNowAsUser({
            latitude:             lat,
            longitude:            lng,
            battery:              battery,
            selfieImageBase64:    this.selfiePreview || null,
            odometerImageBase64:  this.odometerPreview || null,
            fileName:             'punch_' + Date.now() + '.jpg',
            punchType:            this.punchType,
            wfhActivity:          this.wfhActivity,
            transportType:        this.transportType,
            vehicleType:          this.vehicleType,
            odometerReading:      this.odometerReading ? Number(this.odometerReading) : null,
            extractedOdometer:    this.extractedOdometer ? Number(this.extractedOdometer) : null
        })
            .then((state) => {
                this.currentStatus   = state.currentStatus;
                this.lastPunchTime   = state.lastPunchTime;
                this.lastBattery     = state.lastBattery;
                this.lastLat         = state.lastLat;
                this.lastLng         = state.lastLng;
                this.lastOdometerUrl = state.lastOdometerUrl;
                this.lastPunchType   = state.lastPunchType;
                this.isPunching      = false;
                
                // Clear state after successful punch
                this.selfiePreview = '';
                this.odometerPreview = '';
                this.wfhActivity = '';
                this.odometerReading = '';
                this.extractedOdometer = '';
                
                const action = this.isPunchedIn ? 'punched in' : 'punched out';
                this.showToast('Success', `You have successfully ${action}.`, 'success');
            })
            .catch((err) => {
                console.error('UserPunch - punchNowAsUser error', err);
                this.isPunching = false;
                const msg = (err.body && err.body.message) ? err.body.message : 'Punch failed. Please try again.';
                this.error = msg;
                this.showToast('Error', msg, 'error');
            });
    }

    // ── Camera helpers ─────────────────────────────────────────────────────
    initCameras() {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
            console.warn('Camera not supported on this device.');
            return;
        }

        this.stopStreams();

        // 1. Selfie Stream (Front Camera)
        const selfieVideo = this.template.querySelector('.up-video-selfie');
        if (selfieVideo) {
            navigator.mediaDevices.getUserMedia({
                video: { facingMode: 'user' },
                audio: false
            })
            .then((stream) => {
                this.selfieStream = stream;
                selfieVideo.srcObject = stream;
                selfieVideo.play();
                this.videoInitialized = true;
            })
            .catch((err) => console.warn('Selfie camera error:', err.message));
        }

        // 2. Odometer Stream (Rear Camera)
        const odoVideo = this.template.querySelector('.up-video-odometer');
        if (odoVideo) {
            navigator.mediaDevices.getUserMedia({
                video: { facingMode: { ideal: 'environment' } },
                audio: false
            })
            .then((stream) => {
                this.odoStream = stream;
                odoVideo.srcObject = stream;
                odoVideo.play();
                this.videoInitialized = true;
            })
            .catch((err) => console.warn('Odometer camera error:', err.message));
        }
    }

    stopStreams() {
        if (this.selfieStream) {
            this.selfieStream.getTracks().forEach(track => track.stop());
            this.selfieStream = null;
        }
        if (this.odoStream) {
            this.odoStream.getTracks().forEach(track => track.stop());
            this.odoStream = null;
        }
    }

    captureSelfie() {
        const video = this.template.querySelector('.up-video-selfie');
        const canvas = this.template.querySelector('canvas');
        if (!video || !canvas) return;
        this.selfiePreview = this.processCapture(video, canvas, 'SELFIE');
    }

    captureOdometer() {
        const video = this.template.querySelector('.up-video-odometer');
        const canvas = this.template.querySelector('canvas');
        if (!video || !canvas) return;
        this.odometerPreview = this.processCapture(video, canvas, 'ODOMETER');
        
        if (this.isPrivateVehicle) {
            // Call AI extraction instead of mock
            this.handleAIExtraction();
        }
    }

    processCapture(video, canvas, type) {
        canvas.width  = video.videoWidth  || 640;
        canvas.height = video.videoHeight || 480;
        const ctx = canvas.getContext('2d');

        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);

        // Timestamp
        const now = new Date();
        const stamp = `${type} - ${now.toLocaleString('en-IN')}`;

        const bannerH = 32;
        ctx.fillStyle = 'rgba(0, 0, 0, 0.6)';
        ctx.fillRect(0, canvas.height - bannerH, canvas.width, bannerH);

        ctx.fillStyle = '#DAA520';
        ctx.font = 'bold 14px sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(stamp, canvas.width / 2, canvas.height - bannerH / 2);

        return canvas.toDataURL('image/jpeg');
    }

    /**
     * NEW METHOD: AI-Powered Odometer Extraction
     * Calls Anthropic Claude API to extract odometer reading from captured image
     */
    handleAIExtraction() {
        if (!this.odometerPreview) {
            this.showToast('Error', 'No odometer image captured', 'error');
            return;
        }

        this.isExtractingOdometer = true;
        this.extractedOdometer = '';
        
        // Show progress toast
        this.showToast('Processing', 'Extracting odometer reading using AI...', 'info');

        extractOdometerReading({ base64Image: this.odometerPreview })
            .then((reading) => {
                this.isExtractingOdometer = false;
                
                if (reading && reading > 0) {
                    this.extractedOdometer = reading;
                    this.showToast(
                        'Success', 
                        `Odometer reading extracted: ${reading} km`, 
                        'success'
                    );
                } else {
                    throw new Error('Invalid reading extracted');
                }
            })
            .catch((error) => {
                console.error('AI Extraction Error:', error);
                this.isExtractingOdometer = false;
                
                const errorMsg = error.body && error.body.message 
                    ? error.body.message 
                    : 'Failed to extract odometer reading. Please retake the photo or enter manually.';
                
                this.showToast('Extraction Failed', errorMsg, 'warning');
                
                // Clear the extracted value on error
                this.extractedOdometer = '';
            });
    }

    /**
     * REMOVED: handleMockExtraction() - replaced by handleAIExtraction()
     */

    retakeSelfie() { this.selfiePreview = ''; }
    retakeOdometer() { 
        this.odometerPreview = ''; 
        this.extractedOdometer = '';
        this.isExtractingOdometer = false;
    }

    // ── Toast ──────────────────────────────────────────────────────────────
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}