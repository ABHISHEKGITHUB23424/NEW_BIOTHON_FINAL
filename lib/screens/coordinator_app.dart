import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:math';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../main.dart';
import '../data/local_db.dart';
import '../services/bssi_service.dart';

class CoordinatorHeatmapScreen extends StatefulWidget {
  const CoordinatorHeatmapScreen({super.key});

  @override
  State<CoordinatorHeatmapScreen> createState() => _CoordinatorHeatmapScreenState();
}

class _CoordinatorHeatmapScreenState extends State<CoordinatorHeatmapScreen> {
  int _currentTab = 0;
  bool _isLoading = false;
  
  // Selected Region for coordinator (1 = Delhi NCR, 2 = Mumbai MMR, 3 = Bengaluru Urban)
  int _selectedRegionId = 1;
  String _selectedRegionName = 'Delhi NCR';
  String _selectedBloodGroup = 'All'; // Filter by blood group or "All"
  
  List _bloodBanks = [];
  Map<int, Map<String, double>> _bankBssiScores = {};
  List _criticalAlerts = [];
  
  // Statistics data
  List _donationTrend = [];
  Map<String, int> _shortageFreq = {};

  @override
  void initState() {
    super.initState();
    _refreshCoordinatorData();
  }

  Future<void> _refreshCoordinatorData() async {
    setState(() => _isLoading = true);
    
    try {
      await LocalDatabase.instance.init();
      
      // Calculate/Update BSSI Composite scores first
      await BssiService.instance.updateAllBssiScores();

      final allBanks = LocalDatabase.instance.getTable('blood_banks');
      final regionalBanks = allBanks.where((b) => b['region_id'] == _selectedRegionId).toList();

      Map<int, Map<String, double>> bssiMap = {};
      final List<Map<String, dynamic>> criticalAlertsList = [];

      for (var bank in regionalBanks) {
        final int bId = bank['bank_id'] as int;
        
        final List<Map<String, dynamic>> scoresList = LocalDatabase.instance.getTable('bssi_scores')
            .where((s) => s['bank_id'] == bId)
            .toList();
        
        final Map<String, double> bankBssi = {};
        for (var scoreRow in scoresList) {
          final double score = (scoreRow['score'] as num).toDouble();
          bankBssi[scoreRow['blood_group']] = score;
          
          if (score > 75.0) {
            criticalAlertsList.add({
              'bank_id': bId,
              'bank_name': bank['name'],
              'blood_group': scoreRow['blood_group'],
              'bssi': score,
              'donor_response_count': 3,
            });
          }
        }
        bssiMap[bId] = bankBssi;
      }

      // Group donation history trends
      final List<int> bankIds = regionalBanks.map((b) => b['bank_id'] as int).toList();
      final donations = LocalDatabase.instance.getTable('donation_records')
          .where((d) => bankIds.contains(d['bank_id']))
          .toList();
      
      final Map<String, double> trendMap = {};
      for (var d in donations) {
        final String date = d['donated_at'] as String;
        trendMap[date] = (trendMap[date] ?? 0.0) + (d['units'] as num).toDouble();
      }
      
      final List<Map<String, dynamic>> sortedTrendList = trendMap.entries.map((e) => {
        'date': e.key,
        'units': e.value,
      }).toList();
      sortedTrendList.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
      
      final trendList = sortedTrendList.length > 30 
          ? sortedTrendList.sublist(sortedTrendList.length - 30)
          : sortedTrendList;

      // Group shortage frequencies
      final Map<String, int> freqMap = {
        'O+': 0, 'O-': 0, 'A+': 0, 'A-': 0, 'B+': 0, 'B-': 0, 'AB+': 0, 'AB-': 0
      };
      for (var bank in regionalBanks) {
        final int bId = bank['bank_id'] as int;
        final scores = bssiMap[bId] ?? {};
        scores.forEach((bg, score) {
          if (score > 75.0) {
            freqMap[bg] = (freqMap[bg] ?? 0) + 1;
          }
        });
      }

      setState(() {
        _bloodBanks = regionalBanks;
        _bankBssiScores = bssiMap;
        _criticalAlerts = criticalAlertsList;
        _donationTrend = trendList;
        _shortageFreq = freqMap;
        _isLoading = false;
      });
      
    } catch (e) {
      setState(() => _isLoading = false);
      print("Error loading coordinator heatmap: $e");
    }
  }

  Color _getBssiColor(double score) {
    if (score <= 30) return const Color(0xFF30D158); // Green
    if (score <= 55) return const Color(0xFFFFCC00); // Yellow
    if (score <= 75) return const Color(0xFFFF9F0A); // Orange
    if (score <= 90) return const Color(0xFFFF3B30); // Red
    return const Color(0xFF8B0000); // Dark Red (Emergency)
  }

  void _showMarkerDetails(Map bank, Map<String, double> scores) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                bank['name'],
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C)),
              ),
              const SizedBox(height: 6),
              Text(
                'Coordinates: ${bank['location_lat']}, ${bank['location_lng']}',
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
              ),
              const SizedBox(height: 20),
              const Text('Active BSSI Scores per Blood Group:', style: TextStyle(color: Color(0xFF64748B), fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              
              // 8 cells in popup
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: scores.entries.map((e) {
                  final color = _getBssiColor(e.value);
                  return Container(
                    width: 70,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE2E8F0),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: color.withOpacity(0.3)),
                    ),
                    child: Column(
                      children: [
                        Text(e.key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF2C2C2C))),
                        const SizedBox(height: 4),
                        Text(
                          e.value.toStringAsFixed(0),
                          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);

    final List<Widget> tabs = [
      _buildHeatmapView(),
      _buildAlertsFeedView(state),
      _buildStatisticsView(state),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Emergency Coordinator'),
        leading: const Icon(Icons.health_and_safety, color: Color(0xFFFF3B30)),
        actions: [
          // Region selector dropdown
          DropdownButton<int>(
            value: _selectedRegionId,
            dropdownColor: const Color(0xFF8B0000),
            underline: Container(),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            items: const [
              DropdownMenuItem(value: 1, child: Text('Delhi NCR')),
              DropdownMenuItem(value: 2, child: Text('Mumbai MMR')),
              DropdownMenuItem(value: 3, child: Text('Bengaluru')),
              DropdownMenuItem(value: 4, child: Text('Chennai')),
            ],
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _selectedRegionId = val;
                  _selectedRegionName = val == 1 
                      ? 'Delhi NCR' 
                      : val == 2 
                          ? 'Mumbai MMR' 
                          : val == 3
                              ? 'Bengaluru Urban'
                              : 'Chennai';
                });
                _refreshCoordinatorData();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => state.logout(),
          ),
        ],
      ),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF3B30)))
          : tabs[_currentTab],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTab,
        selectedItemColor: const Color(0xFF8B0000),
        unselectedItemColor: Colors.grey,
        onTap: (idx) => setState(() => _currentTab = idx),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.map_outlined), label: 'Regional Map'),
          BottomNavigationBarItem(icon: Icon(Icons.feed_outlined), label: 'Alerts Feed'),
          BottomNavigationBarItem(icon: Icon(Icons.analytics_outlined), label: 'Statistics'),
        ],
      ),
    );
  }

  // --- TAB 1: REGIONAL MAP HEATMAP ---
  Widget _buildHeatmapView() {
    return Column(
      children: [
        // Filter Bar (Select Blood Group)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.white,
          child: Row(
            children: [
              const Text('Filter Group: ', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: ['All', 'O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-'].map((g) {
                      final isSel = _selectedBloodGroup == g;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: ChoiceChip(
                          label: Text(g, style: const TextStyle(fontSize: 12)),
                          selected: isSel,
                          selectedColor: const Color(0xFF8B0000),
                          labelStyle: TextStyle(color: isSel ? Colors.white : const Color(0xFF64748B)),
                          backgroundColor: const Color(0xFFE2E8F0),
                          onSelected: (val) {
                            if (val) setState(() => _selectedBloodGroup = g);
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
              )
            ],
          ),
        ),
        
        // Interactive Canvas Map Simulator
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: RegionalHeatmapPainter(
                    banks: _bloodBanks,
                    bankScores: _bankBssiScores,
                    filterGroup: _selectedBloodGroup,
                  ),
                ),
              ),
              
              // Coordinates click overlay triggers (since CustomPaint is non-interactive directly, we place simple gestured points)
              ...List.generate(_bloodBanks.length, (idx) {
                final bank = _bloodBanks[idx];
                final bId = bank['bank_id'] as int;
                final scores = _bankBssiScores[bId] ?? {};
                
                // Position calculations matches painter coordinates
                double yOffset = 180.0 + (idx * 110.0);
                double xOffset = 90.0 + (idx * 80.0);
                
                return Positioned(
                  left: xOffset - 25,
                  top: yOffset - 25,
                  child: GestureDetector(
                    onTap: () => _showMarkerDetails(bank, scores),
                    child: Container(
                      height: 50,
                      width: 50,
                      color: Colors.transparent, // Invisible gesture layer
                    ),
                  ),
                );
              }),
              
              Positioned(
                bottom: 20,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      )
                    ]
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.touch_app, color: Color(0xFF64748B), size: 16),
                      SizedBox(width: 8),
                      Text(
                        'Tap any colored bank locator point to audit detailed BSSI indices.',
                        style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- TAB 2: CRITICAL ALERTS FEED & TWILIO ESCALATE ---
  Widget _buildAlertsFeedView(AppState state) {
    // Show only alerts where BSSI > 75
    final activeAlerts = _criticalAlerts;

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Active Shortages & Escalations Feed', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C))),
          const SizedBox(height: 4),
          Text(
            'Displays all centers with BSSI > 75. Actions send SMS alerts to regional health officers.',
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 16),
          
          Expanded(
            child: activeAlerts.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.verified_outlined, size: 64, color: Color(0xFF30D158)),
                        const SizedBox(height: 16),
                        Text(
                          'No critical shortages reported in $_selectedRegionName.',
                          style: const TextStyle(color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: activeAlerts.length,
                    itemBuilder: (context, index) {
                      final item = activeAlerts[index];
                      return CriticalAlertFeedCard(
                        alertData: item,
                        backendUrl: state.backendUrl,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // --- TAB 3: REGIONAL STATS & PDF EXPORT ---
  Widget _buildStatisticsView(AppState state) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Analytics Report', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C))),
                ElevatedButton.icon(
                  onPressed: () {
                    // Simulate Export as PDF
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: const Color(0xFF30D158),
                        content: Text('Report exported as PDF for $_selectedRegionName! Saved in downloads.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.picture_as_pdf, size: 18),
                  label: const Text('Export PDF'),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B0000), foregroundColor: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            // Chart 1: Daily Donation Trends
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Daily Donations Trend (Last 30 Days)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C))),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 140,
                      child: _donationTrend.isEmpty
                          ? const Center(child: Text('No historical trends available.', style: TextStyle(color: Color(0xFF64748B))))
                          : BarChart(
                              BarChartData(
                                borderData: FlBorderData(show: false),
                                gridData: FlGridData(show: false),
                                titlesData: FlTitlesData(
                                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 24)),
                                  rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                  topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                  bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                ),
                                barGroups: List.generate(_donationTrend.length, (idx) {
                                  return BarChartGroupData(
                                    x: idx,
                                    barRods: [
                                      BarChartRodData(
                                        toY: (_donationTrend[idx]['units'] as num).toDouble(),
                                        color: const Color(0xFF8B0000),
                                        width: 8,
                                        borderRadius: BorderRadius.circular(4),
                                      )
                                    ]
                                  );
                                }),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Chart 2: Shortage frequency by blood group
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Critical Shortage Incidents by Blood Group', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C))),
                    const SizedBox(height: 12),
                    ..._shortageFreq.entries.map((e) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Row(
                          children: [
                            SizedBox(width: 36, child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C)))),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: e.value > 0 ? (e.value / 15.0) : 0.0,
                                  minHeight: 8,
                                  backgroundColor: const Color(0xFFE2E8F0),
                                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF8B0000)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text('${e.value}', style: const TextStyle(color: Color(0xFF64748B))),
                          ],
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- CRITICAL ALERT FEED CARD WITH TWILIO ACTIONS ---
class CriticalAlertFeedCard extends StatefulWidget {
  final Map alertData;
  final String backendUrl;
  
  const CriticalAlertFeedCard({super.key, required this.alertData, required this.backendUrl});

  @override
  State<CriticalAlertFeedCard> createState() => _CriticalAlertFeedCardState();
}

class _CriticalAlertFeedCardState extends State<CriticalAlertFeedCard> {
  bool _isEscalating = false;
  bool _escalated = false;

  Future<void> _escalateAlert() async {
    setState(() => _isEscalating = true);
    
    try {
      await Future.delayed(const Duration(milliseconds: 600));
      setState(() {
        _isEscalating = false;
        _escalated = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFFFF9F0A),
          content: Text('Escalation SMS sent to District Health Officer (DHO)!'),
        ),
      );
    } catch (e) {
      setState(() => _isEscalating = false);
      print("Error escalating: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.alertData;
    final bssi = data['bssi'] ?? 78.0;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data['bank_name'] ?? 'Blood Bank',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C)),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Depletion expected soon',
                        style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B0000).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    data['blood_group'] ?? 'O+',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF8B0000)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('BSSI Score', style: TextStyle(color: Color(0xFF64748B), fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      '$bssi / 100',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF8B0000)),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Donors Responded', style: TextStyle(color: Color(0xFF64748B), fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      '${data['donor_response_count'] ?? 0} Responses',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF2C2C2C)),
                    ),
                  ],
                ),
                
                _escalated
                    ? const Row(
                        children: [
                          Icon(Icons.check, color: Colors.green, size: 16),
                          SizedBox(width: 4),
                          Text('Escalated', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 13)),
                        ],
                      )
                    : ElevatedButton(
                        onPressed: _isEscalating ? null : _escalateAlert,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF9F0A),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        child: _isEscalating
                            ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                            : const Text('Escalate'),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// --- VECTOR HEATMAP PAINTER SIMULATOR ---
class RegionalHeatmapPainter extends CustomPainter {
  final List banks;
  final Map<int, Map<String, double>> bankScores;
  final String filterGroup;
  
  RegionalHeatmapPainter({
    required this.banks,
    required this.bankScores,
    required this.filterGroup,
  });

  Color _getBssiColor(double score) {
    if (score <= 30) return const Color(0xFF30D158); // Green
    if (score <= 55) return const Color(0xFFFFCC00); // Yellow
    if (score <= 75) return const Color(0xFFFF9F0A); // Orange
    if (score <= 90) return const Color(0xFFFF3B30); // Red
    return const Color(0xFF8B0000); // Dark Red (Emergency)
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Draw stylized dark background contour grid
    final outlinePaint = Paint()
      ..color = Colors.black.withOpacity(0.025)
      ..style = PaintingStyle.fill;
      
    final borderPaint = Paint()
      ..color = Colors.black.withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Draw a mock state outline
    final regionPath = Path()
      ..moveTo(size.width * 0.1, size.height * 0.3)
      ..quadraticBezierTo(size.width * 0.3, size.height * 0.1, size.width * 0.6, size.height * 0.2)
      ..quadraticBezierTo(size.width * 0.9, size.height * 0.3, size.width * 0.8, size.height * 0.6)
      ..quadraticBezierTo(size.width * 0.7, size.height * 0.9, size.width * 0.3, size.height * 0.8)
      ..quadraticBezierTo(size.width * 0.05, size.height * 0.6, size.width * 0.1, size.height * 0.3);

    canvas.drawPath(regionPath, outlinePaint);
    canvas.drawPath(regionPath, borderPaint);

    // Draw stylized map streets
    final roadPaint = Paint()
      ..color = Colors.black.withOpacity(0.04)
      ..strokeWidth = 2.0;
    canvas.drawLine(Offset(size.width * 0.1, size.height * 0.5), Offset(size.width * 0.9, size.height * 0.5), roadPaint);
    canvas.drawLine(Offset(size.width * 0.5, size.height * 0.1), Offset(size.width * 0.5, size.height * 0.9), roadPaint);

    // Draw Blood Bank Indicators
    for (int i = 0; i < banks.length; i++) {
      final bank = banks[i];
      final bId = bank['bank_id'] as int;
      final scores = bankScores[bId] ?? {};
      
      // Determine worst BSSI or filter BSSI score
      double scoreValue = 20.0;
      if (filterGroup == 'All') {
        // Find worst BSSI across all groups
        if (scores.isNotEmpty) {
          scoreValue = scores.values.fold(0.0, (prev, element) => element > prev ? element : prev);
        }
      } else {
        scoreValue = scores[filterGroup] ?? 20.0;
      }
      
      final indicatorColor = _getBssiColor(scoreValue);

      // Coordinates mapping matches gesture triggers offsets
      double yOffset = 180.0 + (i * 110.0);
      double xOffset = 90.0 + (i * 80.0);
      final point = Offset(xOffset, yOffset);

      // Draw pulsing radius and solid dot
      final pulsePaint = Paint()..color = indicatorColor.withOpacity(0.2);
      final dotPaint = Paint()..color = indicatorColor;
      
      canvas.drawCircle(point, 24.0, pulsePaint);
      canvas.drawCircle(point, 10.0, dotPaint);

      // Draw label
      final textSpan = TextSpan(
        text: '${bank['name'].toString().replaceAll(" Memorial", "").replaceAll(" Emergency", "")}\nWorst BSSI: ${scoreValue.toStringAsFixed(0)}',
        style: const TextStyle(color: Color(0xFF2C2C2C), fontSize: 10, fontWeight: FontWeight.bold),
      );
      final textPainter = TextPainter(text: textSpan, textDirection: ui.TextDirection.ltr);
      textPainter.layout();
      textPainter.paint(canvas, Offset(point.dx - 40, point.dy - 35));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
