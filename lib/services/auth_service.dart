import '../data/local_db.dart';
import 'bssi_service.dart';

class AuthService {
  static final AuthService instance = AuthService._init();
  AuthService._init();

  final LocalDatabase _db = LocalDatabase.instance;

  // Simple string-based password hashing/obfuscation to avoid external crypto deps
  String _hashPassword(String password) {
    return 'obf_${password.split('').reversed.join('')}';
  }

  bool _verifyPassword(String plain, String hashed) {
    // MD5 '123456' seeded check
    if (hashed == 'e10adc3949ba59abbe56e057f20f883e' && plain == '123456') {
      return true;
    }
    // Coordinator demo password
    if (plain == 'admin123' && (hashed == 'admin123' || hashed == 'obf_321nimda')) {
      return true;
    }
    return _hashPassword(plain) == hashed || plain == hashed;
  }

  // Handle registration for donor
  Future<Map<String, dynamic>> registerDonor({
    required String name,
    required String phone,
    required String password,
    required String dob,
    required double lat,
    required double lng,
    required bool consent,
    String? idDocBase64,
    String? idDocName,
  }) async {
    await _db.init();

    // Check if phone already exists
    final existing = _db.getTable('donors').where((d) => d['phone'] == phone).toList();
    if (existing.isNotEmpty) {
      throw Exception('A donor with this mobile number is already registered.');
    }

    final newDonor = {
      'firebase_uid': 'local_uid_${phone.replaceAll('+', '')}',
      'name': name,
      'phone': phone,
      'blood_group': 'O+', // default will be overwritten by auth_screen blood group dropdown
      'dob': dob,
      'location_lat': lat,
      'location_lng': lng,
      'password_hash': _hashPassword(password),
      'consent_given': consent,
      'id_document_base64': idDocBase64,
      'id_document_name': idDocName,
      'is_eligible': true,
      'response_count': 0,
      'alert_count': 0,
      'response_rate': 0.0,
      'registered_at': DateTime.now().toIso8601String(),
    };

    final created = await _db.insert('donors', newDonor, 'donor_id');
    return created;
  }

  // Handle registration for blood bank
  Future<Map<String, dynamic>> registerBloodBank({
    required String name,
    required String phone,
    required String password,
    required String address,
    required String estDate,
    required double lat,
    required double lng,
    required String regionName,
    String? website,
    String? approvalDocBase64,
    String? approvalDocName,
    List<Map<String, dynamic>>? inventoryData,
  }) async {
    await _db.init();

    // Check if phone already exists
    final existing = _db.getTable('blood_banks').where((b) => b['contact_phone'] == phone).toList();
    if (existing.isNotEmpty) {
      throw Exception('A blood bank with this contact phone is already registered.');
    }

    // Resolve region_id
    final regions = _db.getTable('regions').where((r) => r['name'].toString().toLowerCase().contains(regionName.toLowerCase())).toList();
    int regionId = 1;
    if (regions.isNotEmpty) {
      regionId = regions.first['region_id'] as int;
    }

    final newBank = {
      'name': name,
      'contact_phone': phone,
      'password_hash': _hashPassword(password),
      'address': address,
      'establishment_date': estDate,
      'website_link': website,
      'location_lat': lat,
      'location_lng': lng,
      'region_id': regionId,
      'admin_user_id': 'local_uid_bank_${phone.replaceAll('+', '')}',
      'is_approved': true,
      'approval_document_base64': approvalDocBase64,
      'approval_document_name': approvalDocName,
    };

    final createdBank = await _db.insert('blood_banks', newBank, 'bank_id');
    final int createdBankId = createdBank['bank_id'] as int;

    // Seed default inventory rows
    final bloodGroups = ['O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-'];
    final inventoryMap = {
      for (var item in (inventoryData ?? [])) 
        item['blood_group']: {
          'units': (item['units'] as num).toDouble(),
          'units_expiring_3days': (item['units_expiring_3days'] as num? ?? 0.0).toDouble()
        }
    };

    for (var bg in bloodGroups) {
      final itemData = inventoryMap[bg];
      final double units = itemData?['units'] ?? 0.0;
      final double expiring = itemData?['units_expiring_3days'] ?? 0.0;
      
      final newInventoryItem = {
        'bank_id': createdBankId,
        'blood_group': bg,
        'units_available': units,
        'units_expiring_3days': expiring,
        'last_updated': DateTime.now().toIso8601String(),
      };
      await _db.insert('blood_inventory', newInventoryItem, 'inventory_id');
      // Trigger initial BSSI
      await BssiService.instance.computeBssi(createdBankId, bg);
    }

    return createdBank;
  }

  // Handle Login and return user profiles
  Future<Map<String, dynamic>> login(String phone, String password, String role) async {
    await _db.init();

    final String cleanPhone = phone.trim();

    if (role == 'coordinator') {
      // Demo coordinator credentials check
      final demoCoordinators = {'coordinator', '+919999999999', 'coord'};
      if (demoCoordinators.contains(cleanPhone.toLowerCase()) && password == 'admin123') {
        return {
          'status': 'success',
          'token': 'mock_jwt_token_coordinator',
          'role': 'coordinator',
          'profile': {
            'firebase_uid': 'mock_uid_coordinator',
            'name': 'Regional Health Coordinator',
            'phone': phone,
            'city': 'Delhi NCR',
          }
        };
      } else {
        throw Exception("Invalid credentials. Use 'coordinator' and 'admin123'.");
      }
    }

    if (role == 'donor') {
      final donors = _db.getTable('donors').where((d) => d['phone'] == cleanPhone).toList();
      if (donors.isEmpty) {
        throw Exception('Invalid credentials. Phone number not found.');
      }
      final donor = donors.first;
      if (!_verifyPassword(password, donor['password_hash'] as String)) {
        throw Exception('Invalid credentials. Incorrect password.');
      }
      return {
        'status': 'success',
        'token': 'mock_jwt_token_donor_${donor['donor_id']}',
        'role': 'donor',
        'profile': donor,
      };
    }

    if (role == 'bank_admin') {
      final banks = _db.getTable('blood_banks').where((b) => b['contact_phone'] == cleanPhone).toList();
      if (banks.isEmpty) {
        throw Exception('Invalid credentials. Blood bank contact phone not found.');
      }
      final bank = banks.first;
      if (!_verifyPassword(password, bank['password_hash'] as String)) {
        throw Exception('Invalid credentials. Incorrect password.');
      }
      return {
        'status': 'success',
        'token': 'mock_jwt_token_bank_${bank['bank_id']}',
        'role': 'bank_admin',
        'profile': bank,
      };
    }

    throw Exception('Invalid portal role.');
  }
}
