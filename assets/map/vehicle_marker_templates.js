/**
 * vehicle_marker_templates.js
 * Vehicle Marker Templates and Registry for WAYDROP
 */

const VEHICLE_REGISTRY = {
  bike: {
    width: 65,
    height: 65,
    supportsDriverOverlay: true,
    color: '#10B981', // green theme
    svgTemplate: (color) => `
      <svg viewBox="0 0 100 100" width="100%" height="100%">
        <defs>
          <linearGradient id="bikeGrad" x1="0%" y1="0%" x2="0%" y2="100%">
            <stop offset="0%" stop-color="#1E293B"/>
            <stop offset="100%" stop-color="#0F172A"/>
          </linearGradient>
        </defs>
        <!-- Wheels -->
        <rect x="47" y="6" width="6" height="16" rx="2" fill="#090D16"/>
        <rect x="46" y="76" width="8" height="20" rx="3" fill="#090D16"/>
        
        <!-- Main Chassis & Body -->
        <path d="M50,15 C42,22 36,45 36,68 C36,80 42,84 50,84 C58,84 64,80 64,68 C64,45 58,22 50,15 Z" fill="url(#bikeGrad)" stroke="${color}" stroke-width="2.5"/>
        
        <!-- Handlebars -->
        <path d="M22,25 Q50,22 78,25 L76,29 Q50,26 24,29 Z" fill="#475569" stroke="#0F172A" stroke-width="1"/>
        <circle cx="21" cy="27" r="3" fill="#090D16"/>
        <circle cx="79" cy="27" r="3" fill="#090D16"/>
        
        <!-- Windshield -->
        <path d="M38,25 Q50,20 62,25 L50,32 Z" fill="#06B6D4" opacity="0.8"/>
        <!-- Seat -->
        <path d="M43,48 C43,44 57,44 57,48 C57,64 54,72 50,72 C46,72 43,64 43,48 Z" fill="#334155" stroke="#1E293B" stroke-width="1.5"/>
        <!-- EV center indicator -->
        <circle cx="50" cy="40" r="3.5" fill="${color}" filter="drop-shadow(0px 0px 2px ${color})"/>
      </svg>
    `
  },
  auto: {
    width: 70,
    height: 70,
    supportsDriverOverlay: true,
    color: '#D97706', // amber/yellow auto theme
    svgTemplate: (color) => `
      <svg viewBox="0 0 100 100" width="100%" height="100%">
        <defs>
          <linearGradient id="autoGrad" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" stop-color="#F59E0B"/>
            <stop offset="100%" stop-color="#D97706"/>
          </linearGradient>
        </defs>
        <!-- Front wheel -->
        <rect x="46" y="6" width="8" height="15" rx="3" fill="#090D16"/>
        <!-- Rear wheels -->
        <rect x="13" y="72" width="8" height="20" rx="3" fill="#090D16"/>
        <rect x="79" y="72" width="8" height="20" rx="3" fill="#090D16"/>
        <rect x="18" y="78" width="64" height="6" fill="#334155"/>
        
        <!-- Main Chassis -->
        <path d="M50,12 C28,28 20,46 20,78 C20,86 28,90 50,90 C72,90 80,86 80,78 C80,46 72,28 50,12 Z" fill="url(#autoGrad)" stroke="#1E293B" stroke-width="2.5"/>
        <!-- Dark cabin roof top view -->
        <path d="M50,22 C32,32 25,48 25,76 L75,76 C75,48 68,32 50,22 Z" fill="#0F172A" stroke="${color}" stroke-width="1.5"/>
        <!-- Windshield -->
        <path d="M30,26 Q50,20 70,26 L66,31 Q50,25 34,31 Z" fill="#06B6D4" opacity="0.8"/>
        <!-- Headlight glowing beam -->
        <polygon points="50,12 36,2 64,2" fill="#FDE047" opacity="0.3"/>
        <circle cx="50" cy="11" r="2.5" fill="#FDE047"/>
      </svg>
    `
  },
  cab: {
    width: 75,
    height: 75,
    supportsDriverOverlay: false,
    color: '#475569', // slate car theme
    svgTemplate: (color) => `
      <svg viewBox="0 0 100 100" width="100%" height="100%">
        <defs>
          <linearGradient id="cabGrad" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" stop-color="#1E293B"/>
            <stop offset="50%" stop-color="#0F172A"/>
            <stop offset="100%" stop-color="#1E293B"/>
          </linearGradient>
        </defs>
        <!-- Ambient outer glow circle -->
        <circle cx="50" cy="50" r="42" fill="none" stroke="${color}" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
        <!-- Wheels -->
        <rect x="14" y="22" width="6" height="15" rx="3" fill="#090D16" />
        <rect x="80" y="22" width="6" height="15" rx="3" fill="#090D16" />
        <rect x="12" y="68" width="8" height="18" rx="3" fill="#090D16" />
        <rect x="80" y="68" width="8" height="18" rx="3" fill="#090D16" />
        
        <!-- Car Main Body -->
        <path d="M50,10 C22,18 20,40 20,74 C20,86 28,90 50,90 C72,90 80,86 80,74 C80,40 78,18 50,10 Z" fill="url(#cabGrad)" stroke="${color}" stroke-width="2.5" />
        
        <!-- Windshield -->
        <path d="M28,33 Q50,28 72,33 L68,40 Q50,35 32,40 Z" fill="#06B6D4" opacity="0.8" />
        <!-- Sunroof / Glass Roof -->
        <rect x="34" y="44" width="32" height="18" rx="4" fill="#0891B2" opacity="0.4" stroke="${color}" stroke-width="1"/>
        <!-- Rear Window -->
        <path d="M30,76 Q50,72 70,76 L67,71 Q50,68 33,71 Z" fill="#06B6D4" opacity="0.8" />
        <!-- Headlights -->
        <path d="M24,11 L28,2 Q22,0 16,5 L20,13 Z" fill="#FDE047" opacity="0.4" />
        <path d="M76,11 L72,2 Q78,0 84,5 L80,13 Z" fill="#FDE047" opacity="0.4" />
        <rect x="23" y="10" width="8" height="3" rx="1.5" fill="#FDE047" />
        <rect x="69" y="10" width="8" height="3" rx="1.5" fill="#FDE047" />
        <!-- Tail Lights -->
        <rect x="25" y="88" width="10" height="3" rx="1.5" fill="#EF4444" />
        <rect x="65" y="88" width="10" height="3" rx="1.5" fill="#EF4444" />
      </svg>
    `
  },
  // Future EV and Logistics Types
  bike_ev: {
    width: 48,
    height: 48,
    supportsDriverOverlay: true,
    color: '#059669', // Bright EV emerald green
    svgTemplate: (color) => VEHICLE_REGISTRY.bike.svgTemplate(color)
  },
  auto_ev: {
    width: 54,
    height: 54,
    supportsDriverOverlay: true,
    color: '#10B981', // EV green
    svgTemplate: (color) => VEHICLE_REGISTRY.auto.svgTemplate(color)
  },
  cargo_van: {
    width: 62,
    height: 62,
    supportsDriverOverlay: false,
    color: '#3B82F6', // Blue theme
    svgTemplate: (color) => `
      <svg viewBox="0 0 100 100" width="100%" height="100%">
        <rect x="18" y="10" width="64" height="80" rx="6" fill="#1E293B" stroke="${color}" stroke-width="2"/>
        <!-- Windshield -->
        <path d="M24,28 L76,28 L72,34 L28,34 Z" fill="#38BDF8" opacity="0.7"/>
        <!-- Cargo compartment lines -->
        <rect x="22" y="38" width="56" height="46" rx="2" fill="#334155" stroke="${color}" stroke-width="1" stroke-dasharray="2 2"/>
      </svg>
    `
  },
  mini_truck: {
    width: 66,
    height: 66,
    supportsDriverOverlay: false,
    color: '#8B5CF6', // Purple theme
    svgTemplate: (color) => `
      <svg viewBox="0 0 100 100" width="100%" height="100%">
        <!-- Driver Cabin -->
        <rect x="22" y="10" width="56" height="28" rx="4" fill="#1E293B" stroke="${color}" stroke-width="2"/>
        <!-- Windshield -->
        <path d="M26,24 L74,24 L70,30 L30,30 Z" fill="#38BDF8" opacity="0.7"/>
        <!-- Truck Bed -->
        <rect x="18" y="42" width="64" height="48" rx="2" fill="#334155" stroke="${color}" stroke-width="1.5"/>
      </svg>
    `
  }
};

const MARKER_STYLE_REGISTRY = {
  available: { opacity: 1.0, saturation: 1.0 },
  busy: { opacity: 0.7, saturation: 0.8 },
  offline: { opacity: 0, hidden: true }
};

const DRIVER_SVG = `
  <!-- Human Driver Overlay -->
  <g class="driver-body">
    <!-- Shoulders -->
    <path d="M30,55 Q50,42 70,55 L65,72 Q50,60 35,72 Z" fill="#1E293B"/>
    <!-- WayDrop Green Delivery Bag on Back -->
    <rect x="38" y="58" width="24" height="20" rx="3.5" fill="#10B981" stroke="#FFFFFF" stroke-width="1.8"/>
    <!-- Visor -->
    <path d="M38,36 Q50,28 62,36 Q50,32 38,36 Z" fill="#0F172A"/>
    <!-- Helmet -->
    <circle cx="50" cy="42" r="13" fill="#10B981" stroke="#FFFFFF" stroke-width="2.5"/>
  </g>
`;

const SILHOUETTE_SVG = (color) => `
  <svg viewBox="0 0 100 100" width="100%" height="100%">
    <circle cx="50" cy="50" r="32" fill="${color}" opacity="0.25"/>
    <circle cx="50" cy="50" r="16" fill="${color}" stroke="#FFFFFF" stroke-width="2"/>
  </svg>
`;

const MARKER_CACHE = {};

function getVehicleMarkerHTML(vehicleType, riderName, zoomLevel, isTracked, presenceState) {
  const presence = MARKER_STYLE_REGISTRY[presenceState] || MARKER_STYLE_REGISTRY.available;
  if (presence.hidden) return '';

  const typeNormalized = String(vehicleType || '').toLowerCase().trim();
  const registryKey = VEHICLE_REGISTRY[typeNormalized] ? typeNormalized : (typeNormalized.includes('parcel') || typeNormalized.includes('delivery') ? 'bike' : 'cab');
  const registryConfig = VEHICLE_REGISTRY[registryKey] || VEHICLE_REGISTRY.cab;

  const hasBase64 = (window.GLB_BIKE_BASE64 && window.GLB_BIKE_BASE64.length > 0) ? 'yes' : 'no';
  const cacheKey = `${registryKey}_${zoomLevel}_${isTracked}_${presenceState}_${hasBase64}`;
  if (MARKER_CACHE[cacheKey]) {
    return MARKER_CACHE[cacheKey].replace('{{RIDER_NAME}}', riderName || 'Rider');
  }

  let width, height;
  const isBike = (registryKey === 'bike' || registryKey === 'bike_ev');
  const isAuto = (registryKey === 'auto' || registryKey === 'auto_ev');
  
  if (zoomLevel > 16) {
    if (isBike) { width = 52; height = 52; }
    else if (isAuto) { width = 56; height = 56; }
    else { width = 60; height = 60; }
  } else if (zoomLevel < 14) {
    if (isBike) { width = 42; height = 42; }
    else if (isAuto) { width = 46; height = 46; }
    else { width = 50; height = 50; }
  } else {
    if (isBike) { width = 48; height = 48; }
    else if (isAuto) { width = 52; height = 52; }
    else { width = 55; height = 55; }
  }
  
  let filterStyle = `saturate(${presence.saturation})`;
  let transformStyle = 'scale(1.4)';

  if (isBike) {
    transformStyle = 'scale(1.3)';
  } else if (isAuto) {
    transformStyle = 'scale(1.3)';
  }

  let imgContent = registryConfig.svgTemplate(registryConfig.color);

  const style = `width: ${width}px; height: ${height}px; opacity: ${presence.opacity}; filter: ${filterStyle}; transform: ${transformStyle}; transition: transform 0.15s linear;`;

  // Wrap in a DOM structure
  let labelHTML = '';
  if (isTracked || (zoomLevel > 15 && riderName)) {
    labelHTML = `
      <div style="background: rgba(15, 23, 42, 0.9); backdrop-filter: blur(8px); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; padding: 2px 8px; margin-top: 4px; box-shadow: 0 4px 12px rgba(0,0,0,0.15); pointer-events: none; white-space: nowrap; z-index: 4;">
        <span style="font-size: 9px; font-weight: 800; color: white; letter-spacing: 0.3px;">{{RIDER_NAME}}</span>
      </div>
    `;
  }

  const html = `
    <div class="rider-vehicle-container" style="display:flex; flex-direction:column; align-items:center; position:relative; overflow:visible;">
      <div class="rider-vehicle-icon" style="position:relative; ${style}">
        <!-- Image Asset -->
        ${imgContent}
        <!-- Radial 3D shadow overlay -->
        <div class="vehicle-3d-shadow" style="position:absolute; bottom:-4px; left:10%; right:10%; height:8px; background:radial-gradient(ellipse at center, rgba(9,13,22,0.45) 0%, rgba(9,13,22,0) 70%); border-radius:50%; z-index:-1; pointer-events:none;"></div>
      </div>
      ${labelHTML}
    </div>
  `;

  MARKER_CACHE[cacheKey] = html;
  return html.replace('{{RIDER_NAME}}', riderName || 'Rider');
}

// Export modules to window scope for WebView usage
window.VEHICLE_REGISTRY = VEHICLE_REGISTRY;
window.MARKER_STYLE_REGISTRY = MARKER_STYLE_REGISTRY;
window.getVehicleMarkerHTML = getVehicleMarkerHTML;
