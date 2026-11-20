// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title CertificateRegistry - ระบบออกและตรวจสอบใบรับรองดิจิทัล (SkillTrust Academy)
/// @notice เก็บเฉพาะ Hash ของเอกสารและข้อมูลผู้รับ ไม่เก็บข้อมูลส่วนบุคคลบน Blockchain
contract CertificateRegistry {
    // ---------------- โครงสร้างข้อมูล ----------------
    struct Course {
        string courseId;        // รหัสหลักสูตร เช่น AI101
        string name;            // ชื่อหลักสูตร
        string description;     // รายละเอียดการอบรม
        uint256 trainingHours;  // จำนวนชั่วโมงอบรม
        bool active;
        bool exists;
    }

    struct Certificate {
        string certId;          // รหัสอ้างอิงใบรับรอง (ห้ามซ้ำ)
        string courseId;
        address recipient;      // Wallet ของผู้รับ (ใช้แสดงใน Dashboard)
        bytes32 certHash;       // Hash ของไฟล์ PDF ใบรับรอง
        bytes32 recipientHash;  // Hash ของ ชื่อ+รหัสผู้รับ (แทนข้อมูลส่วนบุคคล)
        uint256 issuedAt;       // วันที่ออก (timestamp)
        address issuer;         // ผู้ออก
        bool revoked;
        uint256 revokedAt;
        string revokeReason;
        bool exists;
    }

    address public admin;                                  // ผู้ดูแลระบบ = ผู้ deploy
    mapping(address => bool) public isIssuer;              // ผู้ได้รับสิทธิ์ออก/เพิกถอน
    mapping(string => Course) private courses;
    string[] private courseIds;
    mapping(string => Certificate) private certificates;
    string[] private certIds;
    mapping(bytes32 => string) private certIdByHash;       // ค้นหาจาก Hash เอกสาร
    mapping(address => string[]) private certsOfRecipient; // สำหรับ Dashboard

    // ---------------- Events (ประวัติตรวจสอบย้อนหลัง) ----------------
    event IssuerUpdated(address indexed account, bool allowed);
    event CourseCreated(string courseId, string name);
    event CertificateIssued(string certId, string courseId, address indexed recipient, bytes32 certHash, address indexed issuer);
    event CertificateRevoked(string certId, string reason, address indexed by);

    // ---------------- สิทธิ์ ----------------
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    modifier onlyAuthorized() {
        require(msg.sender == admin || isIssuer[msg.sender], "Not authorized");
        _;
    }

    constructor() {
        admin = msg.sender;
        isIssuer[msg.sender] = true;
        emit IssuerUpdated(msg.sender, true);
    }

    // ---------------- ผู้ดูแลระบบ ----------------
    function setIssuer(address _account, bool _allowed) external onlyAdmin {
        require(_account != address(0), "Invalid address");
        isIssuer[_account] = _allowed;
        emit IssuerUpdated(_account, _allowed);
    }

    // 1) ลงทะเบียนหลักสูตร
    function createCourse(
        string memory _courseId,
        string memory _name,
        string memory _description,
        uint256 _trainingHours
    ) external onlyAdmin {
        require(bytes(_courseId).length > 0, "Course ID required");
        require(!courses[_courseId].exists, "Course ID already exists");
        courses[_courseId] = Course(_courseId, _name, _description, _trainingHours, true, true);
        courseIds.push(_courseId);
        emit CourseCreated(_courseId, _name);
    }

    function setCourseActive(string memory _courseId, bool _active) external onlyAdmin {
        require(courses[_courseId].exists, "Course not found");
        courses[_courseId].active = _active;
    }

    // 2) ออกใบรับรอง + 3) บันทึก Hash
    function issueCertificate(
        string memory _certId,
        string memory _courseId,
        address _recipient,
        bytes32 _certHash,
        bytes32 _recipientHash
    ) external onlyAuthorized {
        require(bytes(_certId).length > 0, "Certificate ID required");
        require(!certificates[_certId].exists, "Certificate ID already exists");
        require(courses[_courseId].exists, "Course not found");
        require(courses[_courseId].active, "Course is not active");
        require(_recipient != address(0), "Invalid recipient");
        require(_certHash != bytes32(0), "Certificate hash required");
        require(bytes(certIdByHash[_certHash]).length == 0, "Document already registered");

        certificates[_certId] = Certificate({
            certId: _certId,
            courseId: _courseId,
            recipient: _recipient,
            certHash: _certHash,
            recipientHash: _recipientHash,
            issuedAt: block.timestamp,
            issuer: msg.sender,
            revoked: false,
            revokedAt: 0,
            revokeReason: "",
            exists: true
        });
        certIds.push(_certId);
        certIdByHash[_certHash] = _certId;
        certsOfRecipient[_recipient].push(_certId);

        emit CertificateIssued(_certId, _courseId, _recipient, _certHash, msg.sender);
    }

    // 5) เพิกถอน (ไม่ลบข้อมูล เก็บประวัติไว้)
    function revokeCertificate(string memory _certId, string memory _reason) external onlyAuthorized {
        Certificate storage c = certificates[_certId];
        require(c.exists, "Certificate not found");
        require(!c.revoked, "Certificate already revoked");
        require(bytes(_reason).length > 0, "Reason required");

        c.revoked = true;
        c.revokedAt = block.timestamp;
        c.revokeReason = _reason;
        emit CertificateRevoked(_certId, _reason, msg.sender);
    }

    // ---------------- 4) ตรวจสอบ (ใครก็เรียกได้ ไม่เสีย gas) ----------------
    /// @return found มีใบรับรองนี้หรือไม่, status "Valid" / "Revoked" / "Not Found"
    function verifyCertificate(string memory _certId)
        external
        view
        returns (bool found, string memory status, string memory courseName, address recipient, uint256 issuedAt)
    {
        Certificate memory c = certificates[_certId];
        if (!c.exists) return (false, "Not Found", "", address(0), 0);
        return (true, c.revoked ? "Revoked" : "Valid", courses[c.courseId].name, c.recipient, c.issuedAt);
    }

    /// @notice ตรวจว่าไฟล์ PDF (Hash) ตรงกับที่บันทึกไว้ = เอกสารไม่ถูกแก้ไข
    function verifyDocument(string memory _certId, bytes32 _docHash)
        external
        view
        returns (bool hashMatch, bool valid)
    {
        Certificate memory c = certificates[_certId];
        if (!c.exists) return (false, false);
        hashMatch = (c.certHash == _docHash);
        valid = hashMatch && !c.revoked;
    }

    /// @notice ตรวจว่าชื่อ+รหัสผู้รับที่ผู้สมัครแจ้ง ตรงกับที่บันทึกไว้หรือไม่ (ไม่เปิดเผยข้อมูลจริง)
    function verifyRecipient(string memory _certId, bytes32 _recipientHash) external view returns (bool) {
        Certificate memory c = certificates[_certId];
        return c.exists && c.recipientHash == _recipientHash;
    }

    function getCertificate(string memory _certId) external view returns (Certificate memory) {
        require(certificates[_certId].exists, "Certificate not found");
        return certificates[_certId];
    }

    function getCertIdByHash(bytes32 _docHash) external view returns (string memory) {
        return certIdByHash[_docHash];
    }

    // 6) Dashboard ของผู้เข้าอบรม
    function getCertificatesOf(address _recipient) external view returns (string[] memory) {
        return certsOfRecipient[_recipient];
    }

    function getCourse(string memory _courseId) external view returns (Course memory) {
        require(courses[_courseId].exists, "Course not found");
        return courses[_courseId];
    }

    function getAllCourseIds() external view returns (string[] memory) {
        return courseIds;
    }

    function getCertificateCount() external view returns (uint256) {
        return certIds.length;
    }
}
