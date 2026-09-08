import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:waydrop/core/config/env.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:waydrop/modules/support/screens/customer_support_screen.dart';

class TransportMapWidget extends StatefulWidget {
  final double pickupLat;
  final double pickupLng;
  final double? destinationLat;
  final double? destinationLng;
  final String? geometry;
  final List<dynamic>? nearbyRiders;
  final double? riderLat;
  final double? riderLng;
  final Function(String)? onMapMessage;
  final bool isDark;
  final String? riderAvatar;
  final String? riderName;
  final String? vehicleType;
  final bool showSupportButton;
  final bool showRecenterButton;
  final bool showZoomButtons;
  final double? controlsTopOffset;

  const TransportMapWidget({
    super.key,
    required this.pickupLat,
    required this.pickupLng,
    this.destinationLat,
    this.destinationLng,
    this.geometry,
    this.nearbyRiders,
    this.riderLat,
    this.riderLng,
    this.onMapMessage,
    this.isDark = false,
    this.riderAvatar,
    this.riderName,
    this.vehicleType,
    this.showSupportButton = false,
    this.showRecenterButton = false,
    this.showZoomButtons = false,
    this.controlsTopOffset,
  });

  @override
  State<TransportMapWidget> createState() => _TransportMapWidgetState();
}

class _TransportMapWidgetState extends State<TransportMapWidget> with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  WebViewController? _controller;
  bool _isMapReady = false;
  late bool _isDark;
  late AnimationController _pulseController;

  @override
  bool get wantKeepAlive => true;

  String get apiKey => Env.olaMapsApiKey;

  bool get _useMockMap {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  @override
  void initState() {
    super.initState();
    _isDark = widget.isDark;
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    if (!_useMockMap) {
      try {
        _initController();
      } catch (e) {
        debugPrint('Failed to initialize WebView: $e');
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();

    // Phase 2F-B -- explicit WebView teardown, mirroring the Phase 2A rider active-order screen.
    // ola_map_home.html only tears the map/nearby-riders engine down on the document 'unload'
    // event, which does not reliably fire when Flutter disposes the platform WebView without a
    // navigation -- leaking the MapLibre GL context and the nearby-rider AnimationManager RAF
    // loop. All three JS helpers are idempotent; the call is wrapped in try/catch on the JS side
    // and .catchError on the Dart side, and is fire-and-forget because dispose() cannot await.
    // Skipped on the mock/desktop map path (there is no WebView).
    if (!_useMockMap) {
      final controller = _controller;
      if (controller != null) {
        controller
            .runJavaScript(
              'try { '
              'if (typeof destroyNearbyRidersEngine === "function") { destroyNearbyRidersEngine(); } '
              'if (typeof destroyTrackingEngine === "function") { destroyTrackingEngine(); } '
              'if (typeof destroyMap === "function") { destroyMap(); } '
              '} catch (e) {}',
            )
            .catchError((_) {});
      }
    }

    super.dispose();
  }

  void _initController() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'MapHandler',
        onMessageReceived: (message) {
          if (widget.onMapMessage != null) {
            widget.onMapMessage!(message.message);
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) async {
            setState(() {
              _isMapReady = true;
            });
            _triggerInitializeMap();
          },
        ),
      )
      ..loadFlutterAsset('assets/map/ola_map_home.html');

    _controller = controller;
  }

  String? _normalizeGeometry(String? rawGeometry) {
    if (rawGeometry == null || rawGeometry.isEmpty) return null;
    try {
      final parsed = jsonDecode(rawGeometry);
      if (parsed is List) {
        final List<Map<String, double>> normalized = [];
        for (final item in parsed) {
          if (item is Map) {
            final lat = double.tryParse(item['lat']?.toString() ?? '');
            final lng = double.tryParse(item['lng']?.toString() ?? '');
            if (lat != null && lng != null) {
              normalized.add({'lat': lat, 'lng': lng});
            }
          } else if (item is List && item.length >= 2) {
            final double val1 = double.tryParse(item[0]?.toString() ?? '') ?? 0.0;
            final double val2 = double.tryParse(item[1]?.toString() ?? '') ?? 0.0;
            
            // Deduce lat/lng by value ranges since India coordinates are:
            // Lat: ~8 to ~38, Lng: ~68 to ~98.
            // If val1 is larger than 50.0 (like 77.123), it's likely longitude.
            if (val1 > 50.0 && val1 < 100.0) {
              normalized.add({'lat': val2, 'lng': val1});
            } else {
              normalized.add({'lat': val1, 'lng': val2});
            }
          }
        }
        if (normalized.isNotEmpty) {
          return jsonEncode(normalized);
        }
      }
    } catch (e) {
      debugPrint('Error normalizing geometry: $e');
    }
    return rawGeometry;
  }

  void _triggerInitializeMap() {
    if (!_isMapReady || _controller == null) return;

    // 1. Initialize Ola Map centered at Pickup point (passing light/dark theme mode)
    _controller!.runJavaScript(
      'initializeMap("$apiKey", ${widget.pickupLat}, ${widget.pickupLng}, "${_isDark ? "dark" : "light"}");',
    );
    _controller!.runJavaScript(
      'addPickupMarker(${widget.pickupLat}, ${widget.pickupLng});',
    );

    // 2. Plot Destination if provided
    if (widget.destinationLat != null && widget.destinationLng != null) {
      _controller!.runJavaScript(
        'setDestination(${widget.destinationLat}, ${widget.destinationLng});',
      );
    }

    // 3. Render Route geometry if available
    final geom = _normalizeGeometry(widget.geometry);
    if (geom != null && geom.isNotEmpty) {
      _controller!.runJavaScript(
        'updateRoute($geom);',
      );
      _controller!.runJavaScript('fitRouteBounds();');
    } else if (widget.destinationLat != null && widget.destinationLng != null) {
      _controller!.runJavaScript('fitRouteBounds();');
    }

    // 4. Highlight current rider/courier location if tracking is active
    if (widget.riderLat != null && widget.riderLng != null) {
      _controller!.runJavaScript(
        'updateRiderLocation(${widget.riderLat}, ${widget.riderLng}, "${widget.riderAvatar ?? ""}", "${widget.riderName ?? ""}", "${widget.vehicleType ?? ""}");',
      );
    }

    // 5. Plot nearby riders if searching
    if (widget.nearbyRiders != null && widget.nearbyRiders!.isNotEmpty) {
      final jsonRiders = jsonEncode(widget.nearbyRiders);
      _controller!.runJavaScript('showNearbyRiders($jsonRiders);');
    }
  }

  @override
  void didUpdateWidget(covariant TransportMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Update theme state immediately to avoid race conditions on initialization
    if (oldWidget.isDark != widget.isDark) {
      setState(() {
        _isDark = widget.isDark;
      });
      if (_isMapReady && _controller != null) {
        _controller?.runJavaScript('setTheme("${widget.isDark ? "dark" : "light"}");');
      }
    }

    if (!_isMapReady || _controller == null) return;

    // Update nearby riders if changed
    if (oldWidget.nearbyRiders != widget.nearbyRiders) {
      if (widget.nearbyRiders != null) {
        final jsonRiders = jsonEncode(widget.nearbyRiders);
        _controller!.runJavaScript('showNearbyRiders($jsonRiders);');
      }
    }

    // Update pickup marker if it changed
    if (oldWidget.pickupLat != widget.pickupLat ||
        oldWidget.pickupLng != widget.pickupLng) {
      _controller!.runJavaScript(
        'addPickupMarker(${widget.pickupLat}, ${widget.pickupLng});',
      );
    }

    // Update destination marker if it changed
    if (oldWidget.destinationLat != widget.destinationLat ||
        oldWidget.destinationLng != widget.destinationLng) {
      if (widget.destinationLat != null && widget.destinationLng != null) {
        _controller!.runJavaScript(
          'setDestination(${widget.destinationLat}, ${widget.destinationLng});',
        );
        _controller!.runJavaScript('fitRouteBounds();');
      }
    }

    // Update geometry / route line
    if (oldWidget.geometry != widget.geometry) {
      final geom = _normalizeGeometry(widget.geometry);
      if (geom != null && geom.isNotEmpty) {
        _controller!.runJavaScript(
          'updateRoute($geom);',
        );
        _controller!.runJavaScript('fitRouteBounds();');
      }
    }

    // Update rider live location marker (including name, avatar, and vehicle type updates)
    if (oldWidget.riderLat != widget.riderLat ||
        oldWidget.riderLng != widget.riderLng ||
        oldWidget.riderAvatar != widget.riderAvatar ||
        oldWidget.riderName != widget.riderName ||
        oldWidget.vehicleType != widget.vehicleType) {
      if (widget.riderLat != null && widget.riderLng != null) {
        _controller!.runJavaScript(
          'updateRiderLocation(${widget.riderLat}, ${widget.riderLng}, "${widget.riderAvatar ?? ""}", "${widget.riderName ?? ""}", "${widget.vehicleType ?? ""}");',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    if (_useMockMap) {
      return _buildMockMapPlaceholder();
    }

    if (_controller == null) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFF10B981),
          strokeWidth: 2.5,
        ),
      );
    }

    final hasControls = widget.showRecenterButton ||
        widget.showSupportButton ||
        widget.showZoomButtons;

    return Stack(
      children: [
        WebViewWidget(
          controller: _controller!,
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
          },
        ),
        if (hasControls && _isMapReady)
          Positioned(
            top: widget.controlsTopOffset ?? 80,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [

                if (widget.showRecenterButton) ...[
                  _TransportMapBtn(
                    icon: Icons.my_location_rounded,
                    tooltip: 'Recenter on Drop Partner',
                    onTap: () {
                      _controller?.runJavaScript('recenterToRider();');
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                if (widget.showSupportButton) ...[
                  _TransportMapBtn(
                    icon: Icons.support_agent_rounded,
                    tooltip: 'Customer Support',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const CustomerSupportScreen()),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                if (widget.showZoomButtons) ...[
                  _TransportMapBtn(
                    icon: Icons.add,
                    tooltip: 'Zoom In',
                    onTap: () {
                      _controller?.runJavaScript('zoomIn();');
                    },
                  ),
                  const SizedBox(height: 8),
                  _TransportMapBtn(
                    icon: Icons.remove,
                    tooltip: 'Zoom Out',
                    onTap: () {
                      _controller?.runJavaScript('zoomOut();');
                    },
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildMockMapPlaceholder() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mapBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
    final lineColor = isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.03);
    
    return Container(
      color: mapBg,
      child: Stack(
        children: [
          // Street grid overlay
          Positioned.fill(
            child: CustomPaint(
              painter: _MapGridPainter(lineColor: lineColor),
            ),
          ),
          
          // Outer pulsing ring (pickup location glow)
          Center(
            child: AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                return Container(
                  width: 120 * _pulseController.value,
                  height: 120 * _pulseController.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF10B981).withValues(alpha: 1.0 - _pulseController.value),
                      width: 2,
                    ),
                  ),
                );
              },
            ),
          ),
          
          // Inner pickup marker
          Center(
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: Color(0xFF10B981),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Color(0xFF10B981),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),

          // Destination marker if available
          if (widget.destinationLat != null && widget.destinationLng != null) ...[
            Builder(
              builder: (context) {
                final double dLat = widget.destinationLat! - widget.pickupLat;
                final double dLng = widget.destinationLng! - widget.pickupLng;
                final double dx = dLng * 10000;
                final double dy = -dLat * 10000;

                return Align(
                  alignment: Alignment.center,
                  child: Transform.translate(
                    offset: Offset(dx.clamp(-150.0, 150.0), dy.clamp(-150.0, 150.0)),
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                        color: Color(0xFFEF4444),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0xFFEF4444),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
            ),
          ],

          // Rider marker if tracking is active
          if (widget.riderLat != null && widget.riderLng != null) ...[
            Builder(
              builder: (context) {
                final double dLat = widget.riderLat! - widget.pickupLat;
                final double dLng = widget.riderLng! - widget.pickupLng;
                final double dx = dLng * 10000;
                final double dy = -dLat * 10000;

                final vehicle = widget.vehicleType?.toString().toLowerCase() ?? 'bike';
                IconData riderIcon = Icons.directions_bike_rounded;
                if (vehicle == 'auto') {
                  riderIcon = Icons.local_taxi_rounded;
                } else if (vehicle == 'cab' || vehicle == 'car') {
                  riderIcon = Icons.directions_car_rounded;
                }

                return Align(
                  alignment: Alignment.center,
                  child: Transform.translate(
                    offset: Offset(dx.clamp(-150.0, 150.0), dy.clamp(-150.0, 150.0)),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2563EB),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 6,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Icon(
                            riderIcon,
                            color: Colors.white,
                            size: 14,
                          ),
                        ),
                        if (widget.riderName != null) ...[
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.8),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 0.5),
                            ),
                            child: Text(
                              widget.riderName!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }
            ),
          ],
          
          // Floating nearby riders (dots/icons)
          if (widget.nearbyRiders != null)
            ...widget.nearbyRiders!.asMap().entries.map((entry) {
              final idx = entry.key;
              final rider = entry.value;
              // Generate slightly offset mock positions relative to center
              final double angle = (idx * 1.2) + 0.5;
              final double radius = 50.0 + (idx * 20.0) % 60.0;
              final double dx = radius * math.cos(angle);
              final double dy = radius * math.sin(angle);
              
              final vehicle = rider['vehicle_type']?.toString().toLowerCase() ?? 'bike';
              IconData riderIcon = Icons.directions_bike_rounded;
              if (vehicle == 'auto') {
                riderIcon = Icons.local_taxi_rounded;
              } else if (vehicle == 'cab' || vehicle == 'car') {
                riderIcon = Icons.directions_car_rounded;
              }
              
              final double heading = (rider['current_heading'] is num) ? (rider['current_heading'] as num).toDouble() : 0.0;
              final double headingRad = heading * math.pi / 180;
              
              return Align(
                alignment: Alignment.center,
                child: Transform.translate(
                  offset: Offset(dx, dy),
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF10B981), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Transform.rotate(
                      angle: headingRad,
                      child: Icon(
                        riderIcon,
                        color: const Color(0xFF10B981),
                        size: 11,
                      ),
                    ),
                  ),
                ),
              );
            }),
            
          // Mock Map Overlay Info Banner
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0F172A).withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.laptop_chromebook_rounded,
                    color: Color(0xFF10B981),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Mock Map Active • Location: ${widget.pickupLat.toStringAsFixed(4)}, ${widget.pickupLng.toStringAsFixed(4)}\nEnvironment: Desktop/Web',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapGridPainter extends CustomPainter {
  final Color lineColor;
  _MapGridPainter({required this.lineColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Draw horizontal lines
    for (double y = 0; y < size.height; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    // Draw vertical lines
    for (double x = 0; x < size.width; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    
    // Draw diagonal roads
    canvas.drawLine(const Offset(0, 0), Offset(size.width, size.height), paint);
    canvas.drawLine(Offset(0, size.height * 0.7), Offset(size.width * 0.7, 0), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _TransportMapBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  const _TransportMapBtn({required this.icon, required this.onTap, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: tooltip ?? '',
      child: Card(
        elevation: 4,
        shape: const CircleBorder(),
        color: isDark ? const Color(0xFF131926) : Colors.white,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
