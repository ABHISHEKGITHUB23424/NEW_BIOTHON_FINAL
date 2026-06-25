import 'dart:math';
import '../data/local_db.dart';
import 'bssi_service.dart';

class RedistributionService {
  static final RedistributionService instance = RedistributionService._init();
  RedistributionService._init();

  final LocalDatabase _db = LocalDatabase.instance;
  final BssiService _bssi = BssiService.instance;

  // Finds nearby blood banks with a surplus of the requested blood group
  // Surplus is defined as BSSI < 30 (Safe) and inventory units > 40
  Future<List<Map<String, dynamic>>> getRedistributionSuggestions(int bankId, String bloodGroup) async {
    await _db.init();

    final requestingBanks = _db.getTable('blood_banks').where((b) => b['bank_id'] == bankId).toList();
    if (requestingBanks.isEmpty) return [];
    
    final requestingBank = requestingBanks.first;
    final double reqLat = (requestingBank['location_lat'] as num).toDouble();
    final double reqLng = (requestingBank['location_lng'] as num).toDouble();

    final otherBanks = _db.getTable('blood_banks').where((b) => b['bank_id'] != bankId).toList();
    final List<Map<String, dynamic>> suggestions = [];

    for (var supplyingBank in otherBanks) {
      final sId = supplyingBank['bank_id'] as int;

      // Check BSSI of this blood group
      final scores = _db.getTable('bssi_scores')
          .where((s) => s['bank_id'] == sId && s['blood_group'] == bloodGroup)
          .toList();
      
      double scoreVal = 20.0;
      if (scores.isNotEmpty) {
        scoreVal = (scores.first['score'] as num).toDouble();
      }

      // Check inventory
      final inventoryRows = _db.getTable('blood_inventory')
          .where((i) => i['bank_id'] == sId && i['blood_group'] == bloodGroup)
          .toList();
      
      double available = 0.0;
      if (inventoryRows.isNotEmpty) {
        available = (inventoryRows.first['units_available'] as num).toDouble();
      }

      // Surplus conditions: BSSI < 30 (Safe) and stock > 40 units
      if (scoreVal < 30.0 && available > 40.0) {
        final double sLat = (supplyingBank['location_lat'] as num).toDouble();
        final double sLng = (supplyingBank['location_lng'] as num).toDouble();
        final double distance = _bssi.calculateDistance(reqLat, reqLng, sLat, sLng);

        // Suggest transferring half of the excess units above 20
        double suggestedTransfer = ((available - 20.0) / 2.0);
        suggestedTransfer = double.parse(suggestedTransfer.toStringAsFixed(1));
        if (suggestedTransfer < 5.0) suggestedTransfer = 5.0;

        suggestions.add({
          'supplying_bank_id': sId,
          'supplying_bank_name': supplyingBank['name'],
          'distance_km': double.parse(distance.toStringAsFixed(2)),
          'blood_group': bloodGroup,
          'surplus_units': available,
          'suggested_units': suggestedTransfer,
          'contact_phone': supplyingBank['contact_phone'],
        });
      }
    }

    // Sort closest first
    suggestions.sort((a, b) => (a['distance_km'] as num).compareTo(b['distance_km'] as num));
    return suggestions;
  }

  // Create a new redistribution request
  Future<Map<String, dynamic>> createRedistributionRequest({
    required int requestingBankId,
    required int supplyingBankId,
    required String bloodGroup,
    required double suggestedUnits,
  }) async {
    await _db.init();

    final newRequest = {
      'requesting_bank_id': requestingBankId,
      'supplying_bank_id': supplyingBankId,
      'blood_group': bloodGroup,
      'suggested_units': suggestedUnits,
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
    };

    final created = await _db.insert('redistributions', newRequest, 'suggestion_id');
    return created;
  }

  // Update request status (if completed, automatically adjust inventory)
  Future<void> updateRedistributionStatus(int suggestionId, String newStatus) async {
    await _db.init();

    final redistList = _db.getTable('redistributions')
        .where((r) => r['suggestion_id'] == suggestionId)
        .toList();
    if (redistList.isEmpty) return;

    final redist = redistList.first;
    final String oldStatus = redist['status'] as String;

    await _db.update('redistributions', 'suggestion_id', suggestionId, {'status': newStatus});

    // If marked completed, balance the inventories of both banks
    if (newStatus == 'completed' && oldStatus != 'completed') {
      final int reqBankId = redist['requesting_bank_id'] as int;
      final int sBankId = redist['supplying_bank_id'] as int;
      final String bg = redist['blood_group'] as String;
      final double units = (redist['suggested_units'] as num).toDouble();

      // Decrement supplier
      final sInvList = _db.getTable('blood_inventory')
          .where((i) => i['bank_id'] == sBankId && i['blood_group'] == bg)
          .toList();
      if (sInvList.isNotEmpty) {
        final double current = (sInvList.first['units_available'] as num).toDouble();
        await _db.update('blood_inventory', 'inventory_id', sInvList.first['inventory_id'] as int, {
          'units_available': max(0.0, current - units),
          'last_updated': DateTime.now().toIso8601String(),
        });
      }

      // Increment requester
      final reqInvList = _db.getTable('blood_inventory')
          .where((i) => i['bank_id'] == reqBankId && i['blood_group'] == bg)
          .toList();
      if (reqInvList.isNotEmpty) {
        final double current = (reqInvList.first['units_available'] as num).toDouble();
        await _db.update('blood_inventory', 'inventory_id', reqInvList.first['inventory_id'] as int, {
          'units_available': current + units,
          'last_updated': DateTime.now().toIso8601String(),
        });
      }

      // Recompute BSSI for both banks
      await _bssi.computeBssi(reqBankId, bg);
      await _bssi.computeBssi(sBankId, bg);
    }
  }
}
