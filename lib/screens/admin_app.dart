import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../main.dart';
import '../data/local_db.dart';
import '../services/bssi_service.dart';
import '../services/redistribution_service.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  int _currentTab = 0;
  bool _isLoading = false;
  Map<String, dynamic> _inventory = {};
  Map<String, double> _bssiScores = {};
  List _alertHistory = [];
  List _redistributions = [];

  List<String> _bloodGroupsOrder = ["O+", "O-", "A+", "A-", "B+", "B-", "AB+", "AB-"];
  String _activeSort = 'default';

  @override
  void initState() {
    super.initState();
    _refreshData();
  }

  Future<void> _refreshData() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (state.bankId == null) return;
    
    setState(() => _isLoading = true);
    
    try {
      await LocalDatabase.instance.init();
      
      // Calculate/Update BSSI Composite scores first
      await BssiService.instance.updateAllBssiScores();

      // 1. Get Local Inventory Stock
      final invTable = LocalDatabase.instance.getTable('blood_inventory').where((i) => i['bank_id'] == state.bankId).toList();
      final Map<String, dynamic> invMap = {};
      for (var row in invTable) {
        invMap[row['blood_group']] = {
          'units_available': (row['units_available'] as num).toDouble(),
          'units_expiring_3days': (row['units_expiring_3days'] as num).toDouble(),
        };
      }

      // 2. Get Local BSSI Scores
      final bssiTable = LocalDatabase.instance.getTable('bssi_scores').where((s) => s['bank_id'] == state.bankId).toList();
      final Map<String, double> bssiMap = {};
      for (var row in bssiTable) {
        bssiMap[row['blood_group']] = (row['score'] as num).toDouble();
      }

      // 3. Get Local Alert History
      final alertsTable = LocalDatabase.instance.getTable('shortage_alerts').where((a) => a['bank_id'] == state.bankId).toList();

      setState(() {
        _inventory = invMap;
        _bssiScores = bssiMap;
        _alertHistory = alertsTable;
        _applyActiveSort();
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      print("Error refreshing admin dashboard: $e");
    }
  }

  void _applyActiveSort() {
    if (_activeSort == 'bssi') {
      _bloodGroupsOrder.sort((a, b) {
        final bssiA = _bssiScores[a] ?? 0.0;
        final bssiB = _bssiScores[b] ?? 0.0;
        return bssiB.compareTo(bssiA);
      });
    } else if (_activeSort == 'stock') {
      _bloodGroupsOrder.sort((a, b) {
        final stockA = (_inventory[a] ?? {'units_available': 0.0})['units_available'] as num;
        final stockB = (_inventory[b] ?? {'units_available': 0.0})['units_available'] as num;
        return stockA.compareTo(stockB);
      });
    }
  }

  Color _getBssiColor(double score) {
    if (score <= 30) return const Color(0xFF30D158); // Green
    if (score <= 55) return const Color(0xFFFFCC00); // Yellow
    if (score <= 75) return const Color(0xFFFF9F0A); // Orange
    if (score <= 90) return const Color(0xFFFF3B30); // Red
    return const Color(0xFF8B0000); // Dark Red (Emergency)
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);

    final List<Widget> tabs = [
      _buildGridDashboard(state),
      _buildRedistributionsTab(state),
      _buildAlertHistoryTab(state),
      _buildUpdateInventoryTab(state),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('${state.name} Admin'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshData,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => state.logout(),
          ),
        ],
      ),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF8B0000)))
          : tabs[_currentTab],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTab,
        selectedItemColor: const Color(0xFF8B0000),
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        onTap: (idx) => setState(() => _currentTab = idx),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.grid_view), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.swap_horiz), label: 'Redistribution'),
          BottomNavigationBarItem(icon: Icon(Icons.notification_important_outlined), label: 'Alerts Log'),
          BottomNavigationBarItem(icon: Icon(Icons.add_circle_outline), label: 'Log Transaction'),
        ],
      ),
    );
  }

  // --- TAB 1: 8-CELL GRID INVENTORY ---
  Widget _buildGridDashboard(AppState state) {
    double totalUnits = 0.0;
    _inventory.forEach((key, val) {
      totalUnits += (val['units_available'] ?? 0.0) as double;
    });

    int criticalCount = 0;
    _bssiScores.forEach((key, val) {
      if (val > 75.0) criticalCount++;
    });

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row with Title and Dynamic Sort Menu
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth > 850) {
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Inventory & Shortage Severity Index (BSSI)',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey),
                    ),
                    _buildSortRow(),
                  ],
                );
              } else {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Inventory & Shortage Severity Index (BSSI)',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: _buildSortRow(),
                    ),
                  ],
                );
              }
            },
          ),
          const SizedBox(height: 16),

          // Overview Dashboard Cards
          _buildSummaryCards(totalUnits, criticalCount),
          const SizedBox(height: 20),

          // Instructions for manual rearranging
          Row(
            children: [
              const Icon(Icons.info_outline, size: 13, color: Color(0xFF64748B)),
              const SizedBox(width: 6),
              Text(
                'Tip: Long-press and drag any card to manually rearrange your dashboard',
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double width = constraints.maxWidth;
                final int crossAxisCount = width > 1100 ? 4 : (width > 750 ? 3 : 2);
                final double cardWidth = (width - (crossAxisCount - 1) * 16) / crossAxisCount;
                final double childAspectRatio = cardWidth / 160.0; // Fixed 160px height to prevent desktop clipping
                
                return GridView.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: childAspectRatio,
                  ),
                  itemCount: _bloodGroupsOrder.length,
                  itemBuilder: (context, index) {
                    final bg = _bloodGroupsOrder[index];
                    final stock = _inventory[bg] ?? {'units_available': 0.0, 'units_expiring_3days': 0.0};
                    final bssi = _bssiScores[bg] ?? 20.0;
                    final cellColor = _getBssiColor(bssi);
                    
                    return DragTarget<String>(
                      onWillAccept: (data) => data != bg,
                      onAccept: (receivedBg) {
                        setState(() {
                          _activeSort = 'custom';
                          final int oldIndex = _bloodGroupsOrder.indexOf(receivedBg);
                          final int newIndex = _bloodGroupsOrder.indexOf(bg);
                          _bloodGroupsOrder.removeAt(oldIndex);
                          _bloodGroupsOrder.insert(newIndex, receivedBg);
                        });
                      },
                      builder: (context, candidateData, rejectedData) {
                        final bool isOver = candidateData.isNotEmpty;
                        
                        return LongPressDraggable<String>(
                          data: bg,
                          feedback: Material(
                            color: Colors.transparent,
                            child: Opacity(
                              opacity: 0.8,
                              child: SizedBox(
                                width: cardWidth,
                                height: 160,
                                child: HoverableBloodGroupCard(
                                  bloodGroup: bg,
                                  stock: stock,
                                  bssi: bssi,
                                  cellColor: cellColor,
                                  onTap: () {},
                                  index: index,
                                ),
                              ),
                            ),
                          ),
                          childWhenDragging: Opacity(
                            opacity: 0.2,
                            child: HoverableBloodGroupCard(
                              bloodGroup: bg,
                              stock: stock,
                              bssi: bssi,
                              cellColor: cellColor,
                              onTap: () {},
                              index: index,
                            ),
                          ),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: isOver 
                                  ? Border.all(color: cellColor, width: 2) 
                                  : Border.all(color: Colors.transparent, width: 2),
                            ),
                            child: HoverableBloodGroupCard(
                              key: ValueKey(bg),
                              bloodGroup: bg,
                              stock: stock,
                              bssi: bssi,
                              cellColor: cellColor,
                              index: index,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => BloodGroupDetailScreen(
                                      bankId: state.bankId!,
                                      bloodGroup: bg,
                                      currentStock: stock['units_available'],
                                      expiringStock: stock['units_expiring_3days'],
                                      bssiScore: bssi,
                                    ),
                                  ),
                                ).then((_) => _refreshData());
                              },
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSortRow() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSortChip(
          label: 'Default',
          icon: Icons.grid_view_rounded,
          isActive: _activeSort == 'default',
          onTap: () {
            setState(() {
              _activeSort = 'default';
              _bloodGroupsOrder = ["O+", "O-", "A+", "A-", "B+", "B-", "AB+", "AB-"];
            });
          },
        ),
        const SizedBox(width: 8),
        _buildSortChip(
          label: 'Critical First',
          icon: Icons.warning_amber_rounded,
          isActive: _activeSort == 'bssi',
          onTap: () {
            setState(() {
              _activeSort = 'bssi';
              _applyActiveSort();
            });
          },
        ),
        const SizedBox(width: 8),
        _buildSortChip(
          label: 'Lowest Stock',
          icon: Icons.trending_down_rounded,
          isActive: _activeSort == 'stock',
          onTap: () {
            setState(() {
              _activeSort = 'stock';
              _applyActiveSort();
            });
          },
        ),
      ],
    );
  }

  Widget _buildSortChip({
    required String label,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF8B0000) : const Color(0xFFE2E8F0).withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isActive ? const Color(0xFF8B0000) : const Color(0xFFE2E8F0),
          width: 1,
        ),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: const Color(0xFF8B0000).withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                )
              ]
            : [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 14, color: isActive ? Colors.white : const Color(0xFF64748B)),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isActive ? Colors.white : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCards(double totalUnits, int criticalCount) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 620;
        final cardWidth = isNarrow 
            ? (constraints.maxWidth - 12) / 2 
            : (constraints.maxWidth - 32) / 3;
        
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildSummaryCard(
              title: 'Total Stock',
              value: '${totalUnits.toStringAsFixed(1)} Units',
              icon: Icons.water_drop_rounded,
              color: const Color(0xFFFF3B30),
              width: cardWidth,
            ),
            _buildSummaryCard(
              title: 'Critical Shortages',
              value: criticalCount == 0 ? 'No Shortages' : '$criticalCount Groups',
              icon: Icons.notification_important_rounded,
              color: criticalCount == 0 ? const Color(0xFF30D158) : const Color(0xFFFF9F0A),
              width: cardWidth,
            ),
            if (!isNarrow)
              _buildSummaryCard(
                title: 'Operational Status',
                value: 'Fully Synced',
                icon: Icons.cloud_done_rounded,
                color: Colors.blueAccent,
                width: cardWidth,
              ),
          ],
        );
      },
    );
  }

  Widget _buildSummaryCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    required double width,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C)),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  // --- TAB 2: REDISTRIBUTION SUGGESTIONS ---
  Widget _buildRedistributionsTab(AppState state) {
    // Collect all blood groups with BSSI > 75 to display inter-bank suggetions
    final criticalGroups = _bssiScores.entries
        .where((entry) => entry.value > 75.0)
        .map((entry) => entry.key)
        .toList();

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Inter-Bank Redistribution Proposals', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C))),
          const SizedBox(height: 4),
          Text(
            'Automatically appears for blood groups with BSSI > 75 (Critical / Emergency)',
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 16),
          
          Expanded(
            child: criticalGroups.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.check_circle_outline, size: 64, color: Color(0xFF30D158)),
                        const SizedBox(height: 16),
                        const Text(
                          'All blood groups are in safe stock ranges.',
                          style: TextStyle(color: Color(0xFF2C2C2C), fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        const Text('No redistributions required.', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: criticalGroups.length,
                    itemBuilder: (context, index) {
                      final bg = criticalGroups[index];
                      return RedistributionSuggestionCard(
                        bankId: state.bankId!,
                        bloodGroup: bg,
                        backendUrl: state.backendUrl,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // --- TAB 3: ALERT HISTORY ---
  Widget _buildAlertHistoryTab(AppState state) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Shortage Alert History', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          
          Expanded(
            child: _alertHistory.isEmpty
                ? Center(
                    child: Text(
                      'No shortage alerts triggered in the last 30 days.',
                      style: TextStyle(color: Colors.white.withOpacity(0.3)),
                    ),
                  )
                : ListView.builder(
                    itemCount: _alertHistory.length,
                    itemBuilder: (context, index) {
                      final alert = _alertHistory[index];
                      final date = DateTime.parse(alert['triggered_at']);
                      final rate = (alert['response_rate'] * 100).toStringAsFixed(0);
                      
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    '${alert['blood_group']} Mobilization',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.05),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      DateFormat('dd MMM, HH:mm').format(date.toLocal()),
                                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                                    ),
                                  )
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceAround,
                                children: [
                                  _buildStatColumn('BSSI Trigger', '${alert['bssi_at_trigger']}'),
                                  _buildStatColumn('Notified', '${alert['donors_notified']}'),
                                  _buildStatColumn('Responded', '${alert['donors_responded']}'),
                                  _buildStatColumn('Response Rate', '$rate%'),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatColumn(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ],
    );
  }

  // --- TAB 4: UPDATE INVENTORY (LOG DONATION/TRANSFUSION) ---
  Widget _buildUpdateInventoryTab(AppState state) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: LogInventoryTransactionForm(bankId: state.bankId!, backendUrl: state.backendUrl, onCompleted: _refreshData),
      ),
    );
  }
}

// --- BLOOD GROUP DETAILS & LINE CHART FORECAST SCREEN ---
class BloodGroupDetailScreen extends StatefulWidget {
  final int bankId;
  final String bloodGroup;
  final double currentStock;
  final double expiringStock;
  final double bssiScore;
  
  const BloodGroupDetailScreen({
    super.key,
    required this.bankId,
    required this.bloodGroup,
    required this.currentStock,
    required this.expiringStock,
    required this.bssiScore,
  });

  @override
  State<BloodGroupDetailScreen> createState() => _BloodGroupDetailScreenState();
}

class _BloodGroupDetailScreenState extends State<BloodGroupDetailScreen> {
  bool _isLoading = true;
  List _forecasts = [];
  Map<String, dynamic> _bssiFactors = {};
  bool _isTriggering = false;

  @override
  void initState() {
    super.initState();
    _fetchDetails();
  }

  Future<void> _fetchDetails() async {
    try {
      await LocalDatabase.instance.init();

      // 1. Get Forecast Cache
      final forecastsTable = LocalDatabase.instance.getTable('forecast_cache')
          .where((f) => f['bank_id'] == widget.bankId && f['blood_group'] == widget.bloodGroup)
          .toList();
      final List<Map<String, dynamic>> fList = forecastsTable.map((f) => {
        'date': f['forecast_date'],
        'yhat': (f['yhat'] as num).toDouble(),
        'yhat_lower': (f['yhat_lower'] as num).toDouble(),
        'yhat_upper': (f['yhat_upper'] as num).toDouble(),
      }).toList();

      // 2. Compute BSSI detail locally
      final bssiDetail = await BssiService.instance.computeBssi(widget.bankId, widget.bloodGroup);

      setState(() {
        _forecasts = fList;
        _bssiFactors = bssiDetail['factors'] ?? {};
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      print("Error loading blood group detail: $e");
    }
  }

  Future<void> _triggerDonorAlert() async {
    final state = Provider.of<AppState>(context, listen: false);
    showDialog(
      context: context,
      barrierDismissible: false, // Must wait for animation
      builder: (dialogContext) => ProximitySearchAnimationDialog(
        bloodGroup: widget.bloodGroup,
        bssiScore: widget.bssiScore,
        bankId: widget.bankId,
        bankName: state.name,
        bankCity: state.city,
        onScanComplete: (locationData) async {
          setState(() => _isTriggering = true);
          
          try {
            // Log local shortage alert trigger
            final newAlert = {
              'bank_id': widget.bankId,
              'blood_group': widget.bloodGroup,
              'bssi_at_trigger': widget.bssiScore,
              'donors_notified': 300,
              'donors_responded': 0,
              'response_rate': 0.0,
              'triggered_at': DateTime.now().toIso8601String(),
            };
            await LocalDatabase.instance.insert('shortage_alerts', newAlert, 'alert_id');
            
            setState(() => _isTriggering = false);
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: const Color(0xFF30D158),
                content: Text('Alert triggered! 300 eligible donors notified in and around ${locationData['place']}.'),
              ),
            );
            
            final mockNotif = {
              'log_id': 999,
              'bank_name': state.name,
              'distance_km': 0.8,
              'eta_minutes': 3,
              'blood_group': widget.bloodGroup,
              'bssi': widget.bssiScore,
              'bank_lat': locationData['lat'],
              'bank_lng': locationData['lng'],
              'user_start_lat': locationData['user_start_lat'],
              'user_start_lng': locationData['user_start_lng'],
              'message': 'CRITICAL SHORTAGE: ${widget.bloodGroup} needed at ${state.name} immediately!'
            };
            
            state.triggerMockNotification(mockNotif);
          } catch (e) {
            setState(() => _isTriggering = false);
            print("Error triggering alert: $e");
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.bloodGroup} Analytics')),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF3B30)))
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Stock and BSSI stats overview
                    Row(
                      children: [
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                children: [
                                  const Text('Units Available', style: TextStyle(color: Colors.grey, fontSize: 12)),
                                  const SizedBox(height: 8),
                                  Text('${widget.currentStock}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                children: [
                                  const Text('BSSI Severity', style: TextStyle(color: Colors.grey, fontSize: 12)),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${widget.bssiScore.toStringAsFixed(0)}',
                                    style: TextStyle(
                                      fontSize: 24, 
                                      fontWeight: FontWeight.bold,
                                      color: widget.bssiScore > 55 ? const Color(0xFFFF3B30) : const Color(0xFF30D158)
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    
                    // Forecast line chart card
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('7-Day Demand Forecasting (Prophet)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C))),
                            const SizedBox(height: 4),
                            const Text('Predicted consumption vs stock safety line', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                            const SizedBox(height: 24),
                            
                            // LineChart
                            SizedBox(
                              height: 180,
                              child: _forecasts.isEmpty
                                  ? const Center(child: Text('No forecast points cached.', style: TextStyle(color: Color(0xFF64748B))))
                                  : LineChart(
                                      LineChartData(
                                        gridData: FlGridData(show: true, drawVerticalLine: false),
                                        titlesData: FlTitlesData(
                                          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 30)),
                                          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                          bottomTitles: AxisTitles(
                                            sideTitles: SideTitles(
                                              showTitles: true,
                                              getTitlesWidget: (val, meta) {
                                                if (val.toInt() >= 0 && val.toInt() < _forecasts.length) {
                                                  final dt = DateTime.parse(_forecasts[val.toInt()]['date']);
                                                  return Padding(
                                                    padding: const EdgeInsets.only(top: 6.0),
                                                    child: Text(DateFormat('dd').format(dt), style: const TextStyle(fontSize: 10)),
                                                  );
                                                }
                                                return const Text('');
                                              },
                                            ),
                                          ),
                                        ),
                                        borderData: FlBorderData(show: false),
                                        lineBarsData: [
                                          // Projected Demand Line (Red)
                                          LineChartBarData(
                                            spots: List.generate(_forecasts.length, (idx) {
                                              return FlSpot(idx.toDouble(), _forecasts[idx]['yhat']);
                                            }),
                                            isCurved: true,
                                            color: const Color(0xFFFF3B30),
                                            barWidth: 3,
                                            dotData: FlDotData(show: true),
                                          ),
                                          // Safe threshold floor line (dashed Grey)
                                          LineChartBarData(
                                            spots: List.generate(_forecasts.length, (idx) {
                                              return FlSpot(idx.toDouble(), widget.currentStock);
                                            }),
                                            isCurved: false,
                                            color: Colors.grey.withOpacity(0.4),
                                            barWidth: 1.5,
                                            dashArray: [5, 5],
                                            dotData: FlDotData(show: false),
                                          ),
                                        ],
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    // BSSI factor weights breakdown
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('BSSI Factor Weights Breakdown', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C))),
                            const SizedBox(height: 16),
                            _buildFactorProgressBar('Inventory Gap (35%)', _bssiFactors['inventory_gap'] ?? 0.0),
                            const SizedBox(height: 12),
                            _buildFactorProgressBar('Donation Trend (25%)', _bssiFactors['donation_trend'] ?? 0.0),
                            const SizedBox(height: 12),
                            _buildFactorProgressBar('Accident Signal (20%)', _bssiFactors['accident_signal'] ?? 0.0),
                            const SizedBox(height: 12),
                            _buildFactorProgressBar('Rare Group Flag (10%)', _bssiFactors['rare_group'] ?? 0.0),
                            const SizedBox(height: 12),
                            _buildFactorProgressBar('Expiry Pressure (10%)', _bssiFactors['expiry_pressure'] ?? 0.0),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    
                    // Shortage Timeline & Mobilize Actions
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: widget.bssiScore > 55 ? const Color(0xFFFFF5F5) : const Color(0xFFE2E8F0).withOpacity(0.3),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: widget.bssiScore > 55 ? const Color(0xFF8B0000).withOpacity(0.3) : const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(
                                widget.bssiScore > 55 ? Icons.warning_amber : Icons.check_circle_outline,
                                color: widget.bssiScore > 55 ? const Color(0xFF8B0000) : const Color(0xFF30D158),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  widget.bssiScore > 75 
                                      ? '${widget.bloodGroup} is critical. Forecast predicts depletion in 4 days.'
                                      : 'Stock is adequate to cover next 7 days of predicted demand.',
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C)),
                                ),
                              )
                            ],
                          ),
                          if (widget.bssiScore > 55) ...[
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _isTriggering ? null : _triggerDonorAlert,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF8B0000),
                                padding: const EdgeInsets.symmetric(vertical: 16),
                              ),
                              child: _isTriggering
                                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                  : const Text('Trigger Urgent Donor Alert', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildFactorProgressBar(String label, double value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey)),
            Text('${(value * 100).toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 8,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation<Color>(
              value > 0.6 ? const Color(0xFFFF3B30) : const Color(0xFF30D158)
            ),
          ),
        ),
      ],
    );
  }
}

// --- REDISTRIBUTION SUGGESTION CARD ---
class RedistributionSuggestionCard extends StatefulWidget {
  final int bankId;
  final String bloodGroup;
  final String backendUrl;
  
  const RedistributionSuggestionCard({
    super.key,
    required this.bankId,
    required this.bloodGroup,
    required this.backendUrl,
  });

  @override
  State<RedistributionSuggestionCard> createState() => _RedistributionSuggestionCardState();
}

class _RedistributionSuggestionCardState extends State<RedistributionSuggestionCard> {
  bool _isLoading = true;
  List _suggestions = [];

  @override
  void initState() {
    super.initState();
    _fetchSuggestions();
  }

  Future<void> _fetchSuggestions() async {
    try {
      final suggestions = await RedistributionService.instance.getRedistributionSuggestions(widget.bankId, widget.bloodGroup);
      setState(() {
        _suggestions = suggestions;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      print("Error fetching redistribution suggestions: $e");
    }
  }

  Future<void> _requestTransfer(Map suggestion) async {
    try {
      await RedistributionService.instance.createRedistributionRequest(
        requestingBankId: widget.bankId,
        supplyingBankId: suggestion['supplying_bank_id'] as int,
        bloodGroup: widget.bloodGroup,
        suggestedUnits: (suggestion['suggested_units'] as num).toDouble(),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF30D158),
          content: Text('Redistribution transfer request sent to ${suggestion['supplying_bank_name']}!'),
        ),
      );
      _fetchSuggestions();
    } catch (e) {
      print("Error request transfer: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }

    if (_suggestions.isEmpty) {
      return Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            'No nearby blood banks possess surplus of ${widget.bloodGroup} to suggest redistribution.',
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12.0),
          child: Text(
            'Suggestions for ${widget.bloodGroup}',
            style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF8B0000)),
          ),
        ),
        ..._suggestions.map((s) {
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(s['supplying_bank_name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      Text('${s['distance_km']} km away', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Surplus Stock', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          const SizedBox(height: 2),
                          Text('${s['surplus_units']} Units', style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2C2C2C))),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Suggested Transfer', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          const SizedBox(height: 2),
                          Text(
                            '${s['suggested_units']} Units',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                          ),
                        ],
                      ),
                      ElevatedButton(
                        onPressed: () => _requestTransfer(s),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF8B0000),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        child: const Text('Request'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ],
    );
  }
}

// --- UPDATE INVENTORY FORM ---
class LogInventoryTransactionForm extends StatefulWidget {
  final int bankId;
  final String backendUrl;
  final VoidCallback onCompleted;
  
  const LogInventoryTransactionForm({
    super.key,
    required this.bankId,
    required this.backendUrl,
    required this.onCompleted,
  });

  @override
  State<LogInventoryTransactionForm> createState() => _LogInventoryTransactionFormState();
}

class _LogInventoryTransactionFormState extends State<LogInventoryTransactionForm> {
  final _unitsController = TextEditingController();
  final _donorController = TextEditingController();
  final _hospitalController = TextEditingController();
  
  String _selectedBloodGroup = 'O+';
  String _transactionType = 'donation'; // 'donation' (inflow), 'transfusion' (outflow)
  bool _emergencyFlag = false;
  bool _isSaving = false;

  @override
  void dispose() {
    _unitsController.dispose();
    _donorController.dispose();
    _hospitalController.dispose();
    super.dispose();
  }

  Future<void> _submitTransaction() async {
    final units = double.tryParse(_unitsController.text);
    if (units == null || units <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter valid number of units.')),
      );
      return;
    }
    
    setState(() => _isSaving = true);

    try {
      await LocalDatabase.instance.init();

      final invTable = LocalDatabase.instance.getTable('blood_inventory');
      final invRow = invTable.firstWhere(
        (i) => i['bank_id'] == widget.bankId && i['blood_group'] == _selectedBloodGroup,
        orElse: () => {},
      );

      if (invRow.isNotEmpty) {
        final double currentUnits = (invRow['units_available'] as num).toDouble();
        final double newUnits = _transactionType == 'donation' 
            ? currentUnits + units 
            : max(0.0, currentUnits - units);
        
        await LocalDatabase.instance.update(
          'blood_inventory', 
          'inventory_id', 
          invRow['inventory_id'] as int, 
          {
            'units_available': newUnits,
            'last_updated': DateTime.now().toIso8601String(),
          }
        );
        
        // Log to history
        if (_transactionType == 'donation') {
          final newDonation = {
            'donor_id': int.tryParse(_donorController.text) ?? 1,
            'bank_id': widget.bankId,
            'blood_group': _selectedBloodGroup,
            'units': units,
            'donated_at': DateTime.now().toIso8601String().split('T')[0],
            'is_festival_day': false,
            'accident_count_that_day': 0,
            'season': 'Winter',
          };
          await LocalDatabase.instance.insert('donation_records', newDonation, 'record_id');
        } else {
          final newTransfusion = {
            'hospital_id': int.tryParse(_hospitalController.text) ?? 1,
            'blood_group': _selectedBloodGroup,
            'units': units,
            'transfused_at': DateTime.now().toIso8601String().split('T')[0],
            'emergency_flag': _emergencyFlag,
          };
          await LocalDatabase.instance.insert('transfusion_records', newTransfusion, 'record_id');
        }
        
        // Recompute BSSI score immediately
        await BssiService.instance.computeBssi(widget.bankId, _selectedBloodGroup);
      }

      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(backgroundColor: Color(0xFF30D158), content: Text('Inventory record logged successfully!')),
      );
      _unitsController.clear();
      _donorController.clear();
      _hospitalController.clear();
      widget.onCompleted();
    } catch (e) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error updating inventory locally: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Log Donation or Transfusion', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 24),
        
        // Transaction Type Segmented Toggle
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFFE2E8F0),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _transactionType = 'donation'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _transactionType == 'donation' ? const Color(0xFF8B0000) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Inflow (Donation Received)',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _transactionType == 'donation' ? Colors.white : const Color(0xFF64748B),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _transactionType = 'transfusion'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _transactionType == 'transfusion' ? const Color(0xFF8B0000) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Outflow (Transfusion Out)',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _transactionType == 'transfusion' ? Colors.white : const Color(0xFF64748B),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // Blood Group Select
        DropdownButtonFormField<String>(
          value: _selectedBloodGroup,
          decoration: InputDecoration(
            labelText: 'Blood Group',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: Colors.white,
          ),
          items: ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']
              .map((g) => DropdownMenuItem(value: g, child: Text(g)))
              .toList(),
          onChanged: (val) {
            if (val != null) setState(() => _selectedBloodGroup = val);
          },
        ),
        const SizedBox(height: 16),

        // Units input
        TextField(
          controller: _unitsController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Units Volume (e.g. 1.0, 5.0)',
            prefixIcon: const Icon(Icons.water_drop_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: Colors.white,
          ),
        ),
        const SizedBox(height: 16),

        if (_transactionType == 'donation') ...[
          TextField(
            controller: _donorController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Donor ID (Optional)',
              prefixIcon: const Icon(Icons.person_pin_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
        ] else ...[
          TextField(
            controller: _hospitalController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Hospital ID (Optional, defaults to 1)',
              prefixIcon: const Icon(Icons.local_hospital_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Emergency Flag'),
            subtitle: const Text('Check if this is an urgent/critical demand out'),
            value: _emergencyFlag,
            activeColor: const Color(0xFF8B0000),
            onChanged: (val) => setState(() => _emergencyFlag = val),
          ),
        ],
        
        const SizedBox(height: 32),
        ElevatedButton(
          onPressed: _isSaving ? null : _submitTransaction,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF8B0000),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: _isSaving
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('Log Transaction', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
        ),
      ],
    );
  }
}

class HoverableBloodGroupCard extends StatefulWidget {
  final String bloodGroup;
  final Map<String, dynamic> stock;
  final double bssi;
  final Color cellColor;
  final VoidCallback onTap;
  final int index;

  const HoverableBloodGroupCard({
    super.key,
    required this.bloodGroup,
    required this.stock,
    required this.bssi,
    required this.cellColor,
    required this.onTap,
    required this.index,
  });

  @override
  State<HoverableBloodGroupCard> createState() => _HoverableBloodGroupCardState();
}

class _HoverableBloodGroupCardState extends State<HoverableBloodGroupCard> {
  bool _isHovered = false;
  double _opacity = 0.0;
  double _offsetY = 30.0;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.index * 60), () {
      if (mounted) {
        setState(() {
          _opacity = 1.0;
          _offsetY = 0.0;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cellColor = widget.cellColor;
    final stock = widget.stock;
    final bssi = widget.bssi;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 200),
        tween: Tween(begin: 0.0, end: _isHovered ? 1.0 : 0.0),
        builder: (context, hoverProgress, child) {
          final scale = 1.0 + (hoverProgress * 0.04);
          final glowOpacity = 0.4 + (hoverProgress * 0.4);
          final shadowSpread = hoverProgress * 8.0;

          return TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 400),
            tween: Tween(begin: 30.0, end: _offsetY),
            curve: Curves.easeOutBack,
            builder: (context, offset, child) {
              return AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: _opacity,
                child: Transform.translate(
                  offset: Offset(0, offset),
                  child: Transform.scale(
                    scale: scale,
                    child: child,
                  ),
                ),
              );
            },
            child: GestureDetector(
              onTap: widget.onTap,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white,
                      Color.lerp(Colors.white, cellColor, 0.08)!,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: cellColor.withOpacity(glowOpacity),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: cellColor.withOpacity(0.15 * hoverProgress),
                      blurRadius: 12 + shadowSpread,
                      spreadRadius: 1 + (hoverProgress * 2),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Text(
                              widget.bloodGroup,
                              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: Color(0xFF2C2C2C)),
                            ),
                            if (bssi > 75) ...[
                              const SizedBox(width: 8),
                              _PulseWarningDot(color: cellColor),
                            ],
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: cellColor.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: cellColor.withOpacity(0.3), width: 1),
                          ),
                          child: Text(
                            'BSSI ${bssi.toStringAsFixed(0)}',
                            style: TextStyle(color: cellColor, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF2C2C2C),
                        shadows: [
                          if (_isHovered)
                            Shadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 4,
                            ),
                        ],
                      ),
                      child: Text('${stock['units_available']} Units'),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 14,
                          color: stock['units_expiring_3days'] > 0 ? const Color(0xFFFF9F0A) : const Color(0xFF64748B),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Expiring (3d): ${stock['units_expiring_3days']}',
                          style: TextStyle(
                            fontSize: 12,
                            color: stock['units_expiring_3days'] > 0 ? const Color(0xFFFF9F0A) : const Color(0xFF64748B),
                            fontWeight: stock['units_expiring_3days'] > 0 ? FontWeight.w500 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PulseWarningDot extends StatefulWidget {
  final Color color;
  const _PulseWarningDot({required this.color});

  @override
  State<_PulseWarningDot> createState() => _PulseWarningDotState();
}

class _PulseWarningDotState extends State<_PulseWarningDot> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withOpacity(0.5 * _controller.value),
                blurRadius: 6 * _controller.value,
                spreadRadius: 2 * _controller.value,
              ),
            ],
          ),
        );
      },
    );
  }
}

// AI Proximity radar scanning simulation
class ProximitySearchAnimationDialog extends StatefulWidget {
  final String bloodGroup;
  final double bssiScore;
  final int bankId;
  final String bankName;
  final String bankCity;
  final Function(Map<String, dynamic> locationData) onScanComplete;

  const ProximitySearchAnimationDialog({
    super.key,
    required this.bloodGroup,
    required this.bssiScore,
    required this.bankId,
    required this.bankName,
    required this.bankCity,
    required this.onScanComplete,
  });

  @override
  State<ProximitySearchAnimationDialog> createState() => _ProximitySearchAnimationDialogState();
}

class _ProximitySearchAnimationDialogState extends State<ProximitySearchAnimationDialog> {
  double _elapsedSeconds = 0.0;
  Timer? _timer;
  final List<String> _logs = [];
  bool _isComplete = false;
  late Map<String, dynamic> _locData;

  final List<Offset> _donorOffsets = [
    const Offset(-0.3, -0.4),
    const Offset(0.4, -0.2),
    const Offset(-0.2, 0.5),
    const Offset(0.5, 0.4),
    const Offset(-0.5, 0.1),
    const Offset(0.1, -0.6),
    const Offset(0.3, 0.6),
    const Offset(-0.6, -0.3),
    const Offset(0.6, -0.5),
    const Offset(-0.1, 0.3),
    const Offset(0.2, -0.2),
    const Offset(-0.4, 0.6),
  ];

  @override
  void initState() {
    super.initState();
    _locData = _getBankLocationDetails(widget.bankName, widget.bankCity);
    
    _logs.add("[AI ENGINE] Initializing proximity engine...");
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      setState(() {
        _elapsedSeconds += 0.1;
        if (_elapsedSeconds >= 10.0) {
          _elapsedSeconds = 10.0;
          _isComplete = true;
          _timer?.cancel();
          _addLogOnce("[AI SYSTEM] Scanning complete! 300 compatible donors mapped.");
          _addLogOnce("[FCM PUSH] Alerts dispatched via push notifications and Twilio SMS fallbacks.");
        } else {
          _updateLogs();
        }
      });
    });
  }

  Map<String, dynamic> _getBankLocationDetails(String name, String city) {
    String nameLower = name.toLowerCase();
    String cityLower = city.toLowerCase();

    if (nameLower.contains("virugambakkam") || nameLower.contains("chennai") || cityLower.contains("chennai")) {
      return {
        "place": nameLower.contains("virugambakkam") ? "Virugambakkam, Chennai" : "Guindy, Chennai",
        "lat": 13.0424,
        "lng": 80.1914,
        "coords_str": "13.0424° N, 80.1914° E",
        "suburbs": ["Vadapalani", "Saligramam", "Koyambedu", "K.K. Nagar", "Ashok Nagar"],
        "user_start_lat": 13.0494, // Vadapalani
        "user_start_lng": 80.2104,
      };
    } else if (nameLower.contains("koramangala") || nameLower.contains("bengaluru") || nameLower.contains("bangalore") || cityLower.contains("bengaluru") || cityLower.contains("bangalore")) {
      return {
        "place": "Koramangala, Bengaluru",
        "lat": 12.9352,
        "lng": 77.6244,
        "coords_str": "12.9352° N, 77.6244° E",
        "suburbs": ["HSR Layout", "Indiranagar", "Jayanagar", "BTM Layout", "MG Road"],
        "user_start_lat": 12.9279, // HSR Layout
        "user_start_lng": 77.6271,
      };
    } else if (nameLower.contains("mumbai") || nameLower.contains("thane") || nameLower.contains("navi mumbai") || cityLower.contains("mumbai")) {
      return {
        "place": "Nariman Point, Mumbai",
        "lat": 18.9282,
        "lng": 72.8220,
        "coords_str": "18.9282° N, 72.8220° E",
        "suburbs": ["Colaba", "Marine Drive", "Worli", "Bandra", "Andheri"],
        "user_start_lat": 19.0760,
        "user_start_lng": 72.8777,
      };
    } else {
      // Default to Delhi NCR
      return {
        "place": "Connaught Place, Delhi NCR",
        "lat": 28.6304,
        "lng": 77.2177,
        "coords_str": "28.6304° N, 77.2177° E",
        "suburbs": ["Karol Bagh", "Chanakyapuri", "Patel Nagar", "Noida Sector 62", "Gurgaon MG Road"],
        "user_start_lat": 28.6139,
        "user_start_lng": 77.2090,
      };
    }
  }

  void _addLogOnce(String log) {
    if (!_logs.contains(log)) {
      _logs.add(log);
    }
  }

  void _updateLogs() {
    if (_elapsedSeconds >= 1.0) {
      _addLogOnce("[LOCATOR] Coordinate set: ${_locData['place']} (${_locData['coords_str']})");
    }
    if (_elapsedSeconds >= 2.5) {
      String placeName = _locData['place'].toString().split(',')[0];
      _addLogOnce("[SCANNER] Scanning $placeName grid... 130 donors matched.");
    }
    if (_elapsedSeconds >= 4.5) {
      _addLogOnce("[EXPANSION] Radius extended to 5km (${_locData['suburbs'][0]} & ${_locData['suburbs'][1]})... 90 donors matched.");
    }
    if (_elapsedSeconds >= 6.5) {
      _addLogOnce("[EXPANSION] Radius extended to 10km (${_locData['suburbs'][2]} & ${_locData['suburbs'][3]})... 80 donors matched.");
    }
    if (_elapsedSeconds >= 8.0) {
      _addLogOnce("[AI MODEL] Filtering 300 eligible donors (DPDP Act 2023 compliant).");
    }
    if (_elapsedSeconds >= 9.0) {
      _addLogOnce("[ROUTING] Optimizing ETA models based on transit traffic density...");
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double progress = _elapsedSeconds / 10.0;
    
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 480,
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.psychology_outlined, color: Color(0xFF8B0000), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'AI Proximity Search',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      Text(
                        'Matching ${widget.bloodGroup} Donors near ${_locData['place']}',
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                if (_isComplete)
                  const Icon(Icons.check_circle, color: Color(0xFF30D158), size: 24)
                else
                  Text(
                    '${(10 - _elapsedSeconds).toStringAsFixed(1)}s',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF8B0000)),
                  ),
              ],
            ),
            const Divider(height: 24),
            
            // Pulsating Radar Scan Circle
            Center(
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  color: const Color(0xFFFAF8F5),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: CustomPaint(
                  painter: RadarPainter(progress, _donorOffsets),
                ),
              ),
            ),
            const SizedBox(height: 20),
            
            // Progress Bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: const Color(0xFFE2E8F0),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF8B0000)),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 16),
            
            // Dynamic Log Output Container
            Container(
              height: 120,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFAF8F5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  final log = _logs[index];
                  final isFCM = log.startsWith("[FCM") || log.startsWith("[AI SYSTEM");
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6.0),
                    child: Text(
                      log,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: isFCM ? const Color(0xFF389E0D) : Colors.black87,
                        fontWeight: isFCM ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            
            // Bottom Action buttons
            ElevatedButton(
              onPressed: _isComplete
                  ? () {
                      Navigator.pop(context);
                      widget.onScanComplete(_locData);
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B0000),
                disabledBackgroundColor: Colors.grey.shade300,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                _isComplete ? 'Dispatched Alerts (Close)' : 'AI Scan in Progress...',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _isComplete ? Colors.white : Colors.black38,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RadarPainter extends CustomPainter {
  final double progress;
  final List<Offset> donorOffsets;
  RadarPainter(this.progress, this.donorOffsets);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    final gridPaint = Paint()
      ..color = const Color(0xFF8B0000).withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (int i = 1; i <= 4; i++) {
      canvas.drawCircle(center, maxRadius * (i / 4), gridPaint);
    }

    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), gridPaint);
    canvas.drawLine(Offset(center.dx, 0), Offset(center.dx, size.height), gridPaint);

    final sweepRadius = maxRadius * (progress % 0.5) * 2;
    final sweepPaint = Paint()
      ..color = const Color(0xFF8B0000).withOpacity(0.15 * (1.0 - (progress % 0.5) * 2))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, sweepRadius, sweepPaint);

    final ringRadius = maxRadius * (progress % 1.0);
    final ringPaint = Paint()
      ..color = const Color(0xFF8B0000).withOpacity(0.3 * (1.0 - progress % 1.0))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, ringRadius, ringPaint);

    int visibleDonors = (donorOffsets.length * progress).toInt();
    for (int i = 0; i < visibleDonors; i++) {
      final offset = donorOffsets[i];
      final pos = Offset(center.dx + offset.dx * maxRadius, center.dy + offset.dy * maxRadius);
      
      double opacity = ((progress * 10) - i).clamp(0.0, 1.0);
      final dotPaint = Paint()
        ..color = const Color(0xFF8B0000).withOpacity(opacity * 0.9)
        ..style = PaintingStyle.fill;
        
      canvas.drawCircle(pos, 5, dotPaint);

      final pulsePaint = Paint()
        ..color = const Color(0xFF8B0000).withOpacity(opacity * 0.3 * (1.0 - (progress * 3 % 1.0)))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawCircle(pos, 5 + 6 * (progress * 3 % 1.0), pulsePaint);
    }
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.donorOffsets != donorOffsets;
  }
}

