/**
 * Waydrop Ola Maps Core JS Engine
 * API Version: 1.0.0
 */

window.MAP_API_VERSION = "1.0.0";

// Map State Manager
window.MapState = {
    map: null,
    markers: {}, // id -> Marker object
    routes: {},  // id -> source/layer info
    initialized: false,
    isDarkModeActive: false,
    storedApiKey: '',
    userHasInteracted: false,
    firstLoadCompleted: false
};

// ==========================================
// FLUTTER BRIDGE
// ==========================================
window.sendFlutterMessage = function(type, payload) {
    const message = JSON.stringify({
        type: type,
        ...(payload || {})
    });
    if (window.MapHandler && window.MapHandler.postMessage) {
        window.MapHandler.postMessage(message);
    } else if (window.Flutter && window.Flutter.postMessage) {
        window.Flutter.postMessage(message);
    } else if (window.MapChannel && window.MapChannel.postMessage) {
        window.MapChannel.postMessage(message);
    } else {
        console.log(`[MapBridge] ${type}:`, payload);
    }
};

// ==========================================
// ANALYTICS & LOGGING
// ==========================================
window.trackEvent = function(name, metadata) {
    console.log(`[Analytics] Event: ${name}`, metadata || '');
    window.sendFlutterMessage('analytics', { event: name, data: metadata });
};

// ==========================================
// MAP LIFECYCLE & INITIALIZATION
// ==========================================
window.getDynamicPadding = function(defaultPadding) {
    const mapEl = document.getElementById('map');
    const mapHeight = mapEl ? mapEl.clientHeight : window.innerHeight;
    if (mapHeight < 400) {
        const tinyPadding = {};
        if ('top' in defaultPadding) tinyPadding.top = 20;
        if ('bottom' in defaultPadding) tinyPadding.bottom = 20;
        if ('left' in defaultPadding) tinyPadding.left = 20;
        if ('right' in defaultPadding) tinyPadding.right = 20;
        return tinyPadding;
    }
    return defaultPadding;
};

window.initializeMap = function(apiKey, arg1, arg2, arg3, options) {
    options = options || {};
    window.MapState.storedApiKey = apiKey;
    
    let initialLat = 12.9716;
    let initialLng = 77.5946;
    let themeMode = 'light';

    if (typeof arg1 === 'number' && typeof arg2 === 'number') {
        initialLat = arg1;
        initialLng = arg2;
        themeMode = arg3 || 'light';
    } else {
        themeMode = arg1 || 'light';
    }

    window.MapState.isDarkModeActive = (themeMode === 'dark');

    if (window.MapState.isDarkModeActive) {
        document.body.classList.add('dark-theme');
    } else {
        document.body.classList.remove('dark-theme');
    }

    if (!apiKey || apiKey.trim() === '') {
        console.warn('[OlaMap] No API key provided.');
    }
    
    const styleName = window.MapState.isDarkModeActive ? 'default-dark-standard' : 'default-light-standard';
    const styleUrl = `https://api.olamaps.io/tiles/vector/v1/styles/${styleName}/style.json?api_key=${apiKey}`;
    
    window.loadOlaMap(styleUrl, initialLng, initialLat, options);
    
    if (typeof arg1 === 'number' && typeof arg2 === 'number' && options.addInitialPickupMarker) {
        window.addPickupMarker(initialLat, initialLng);
    }
};

window.loadOlaMap = function(styleUrl, centerLng, centerLat, options) {
    // Defensive re-entry guard (WayDrop Phase 2F, F4): every caller today calls this exactly once
    // per WebView, but the line below unconditionally assigns a brand-new maplibregl.Map -- a
    // duplicate call would otherwise orphan the previous map's WebGL context, workers and event
    // listeners with no .remove(). destroyMap() (below) is idempotent and no-ops on a fresh load,
    // so this changes nothing about normal first initialization.
    if (window.MapState.map) {
        window.destroyMap();
    }

    const mapOptions = {
        failIfMajorPerformanceCaveat: false,
        antialias: false,
        pitchWithRotate: false,
        dragRotate: false,
        container: 'map',
        style: styleUrl,
        center: [centerLng || 77.5946, centerLat || 12.9716],
        zoom: options.zoom || 13,
        attributionControl: false,
        transformRequest: (url) => {
            if (url.includes('olamaps.io') && window.MapState.storedApiKey) {
                const cleanUrl = url.replace(/[?&](api_key|key)=[^&]*/g, '');
                const sep = cleanUrl.includes('?') ? '&' : '?';
                url = cleanUrl + sep + 'api_key=' + window.MapState.storedApiKey;
            }
            return { url: url };
        }
    };

    // Perf fix (WayDrop Phase 2A): opt-in, per-caller map tuning. Only applied when the caller
    // explicitly passes these in `options` (currently only ola_map_tracking_rider.html's
    // initTrackingMap), so every other map screen -- home, booking, searching, location picker,
    // passenger tracking -- is byte-for-byte unchanged.
    //   maxTileCacheSize : bounds retained tile memory on a long trip with a lot of camera panning
    //                      (MapLibre's default is an unbounded, viewport-derived heuristic).
    //   fadeDuration     : 0 disables the per-frame symbol/tile cross-fade animation, which
    //                      otherwise keeps the renderer busy for `fadeDuration` ms after every
    //                      camera move -- pure visual polish that a utility tracking map does not need.
    if (typeof options.maxTileCacheSize === 'number') {
        mapOptions.maxTileCacheSize = options.maxTileCacheSize;
    }
    if (typeof options.fadeDuration === 'number') {
        mapOptions.fadeDuration = options.fadeDuration;
    }

    window.MapState.map = new maplibregl.Map(mapOptions);
    window.MapState.initialized = true;

    window.setupMapEvents(window.MapState.map);

    window.MapState.map.on('style.load', () => {
        setTimeout(() => {
            if (window.redrawRouteLines) {
                window.redrawRouteLines();
            }
            window.MapState.map.resize();
        }, 100);
    });

    window.MapState.map.on('error', (e) => {
        // e.error is the actual Error/message; logging the raw ErrorEvent object stringifies to
        // "[object Object]" over the WebView console-to-logcat bridge, which is undiagnosable.
        const detail = e && e.error ? (e.error.message || String(e.error)) : String(e);
        console.error('[OlaMap] Error event:', detail);
    });
};

window.setupMapEvents = function(mapObj) {
    mapObj.on('dragstart', () => {
        window.MapState.userHasInteracted = true;
        window.isFollowingRider = false;
        window.sendFlutterMessage('camera_move_start');
    });
    mapObj.on('zoomstart', () => {
        window.MapState.userHasInteracted = true;
        window.sendFlutterMessage('camera_move_start');
    });
    mapObj.on('moveend', () => {
        const center = mapObj.getCenter();
        window.sendFlutterMessage('camera_move_end', {
            lat: center.lat,
            lng: center.lng
        });
    });
};

window.setTheme = function(theme) {
    const isDark = (theme === 'dark');
    if (window.MapState.isDarkModeActive === isDark) return;
    window.MapState.isDarkModeActive = isDark;
    
    if (window.MapState.isDarkModeActive) {
        document.body.classList.add('dark-theme');
    } else {
        document.body.classList.remove('dark-theme');
    }
    
    if (window.MapState.map && window.MapState.storedApiKey) {
        const styleName = window.MapState.isDarkModeActive ? 'default-dark-standard' : 'default-light-standard';
        const styleUrl = `https://api.olamaps.io/tiles/vector/v1/styles/${styleName}/style.json?api_key=${window.MapState.storedApiKey}`;
        window.MapState.map.setStyle(styleUrl);
    }
};

window.destroyMap = function() {
    window.removeAllMarkers();
    window.clearRoute();
    if (window.MapState.map) {
        window.MapState.map.remove();
        window.MapState.map = null;
    }
    window.MapState.initialized = false;
    window.MapState.storedApiKey = '';
};

// ==========================================
// MARKER MANAGEMENT
// ==========================================
window.removeMarker = function(id) {
    if (window.MapState.markers[id]) {
        window.MapState.markers[id].remove();
        delete window.MapState.markers[id];
    }
};

window.removeAllMarkers = function() {
    Object.keys(window.MapState.markers).forEach(id => {
        window.removeMarker(id);
    });
    window.MapState.markers = {};
};

window.clearMarkers = function() {
    window.removeMarker('pickup');
    window.removeMarker('destination');
};

window.addPickupMarker = function(lat, lng, zoomAfter) {
    if (!window.MapState.map) {
        setTimeout(() => window.addPickupMarker(lat, lng, zoomAfter), 100);
        return;
    }
    window.removeMarker('pickup');

    const el = document.createElement('div');
    el.style.cssText = `
        width: 36px;
        height: 45px;
        cursor: pointer;
        filter: drop-shadow(0px 4px 8px rgba(0,0,0,0.18));
    `;
    el.innerHTML = `
    <svg viewBox="0 0 24 30" width="36" height="45" xmlns="http://www.w3.org/2000/svg">
        <ellipse cx="12" cy="28" rx="6" ry="2" fill="rgba(0,0,0,0.25)" />
        <path d="M12 2 C6.48 2 2 6.48 2 12 C2 19.5 12 28 12 28 C12 28 22 19.5 22 12 C22 6.48 17.52 2 12 2 Z" fill="#10B981" stroke="#FFFFFF" stroke-width="1.8" />
        <circle cx="12" cy="12" r="4.5" fill="#FFFFFF" />
    </svg>
    `;

    const marker = new maplibregl.Marker({ element: el, anchor: 'bottom' })
        .setLngLat([lng, lat])
        .addTo(window.MapState.map);

    window.MapState.markers['pickup'] = marker;

    if (zoomAfter) {
        window.MapState.map.flyTo({
            center: [lng, lat],
            padding: window.getDynamicPadding({ top: 220, bottom: 80 }),
            zoom: zoomAfter,
            duration: 1000
        });
    }
};

window.addDestinationMarker = function(lat, lng, zoomAfter) {
    if (!window.MapState.map) {
        setTimeout(() => window.addDestinationMarker(lat, lng, zoomAfter), 100);
        return;
    }
    window.removeMarker('destination');

    const el = document.createElement('div');
    el.style.cssText = `
        width: 36px;
        height: 45px;
        cursor: pointer;
        filter: drop-shadow(0px 4px 8px rgba(0,0,0,0.18));
    `;
    el.innerHTML = `
    <svg viewBox="0 0 24 30" width="36" height="45" xmlns="http://www.w3.org/2000/svg">
        <ellipse cx="12" cy="28" rx="6" ry="2" fill="rgba(0,0,0,0.25)" />
        <path d="M12 2 C6.48 2 2 6.48 2 12 C2 19.5 12 28 12 28 C12 28 22 19.5 22 12 C22 6.48 17.52 2 12 2 Z" fill="#EF4444" stroke="#FFFFFF" stroke-width="1.8" />
        <circle cx="12" cy="12" r="4.5" fill="#FFFFFF" />
    </svg>
    `;

    const marker = new maplibregl.Marker({ element: el, anchor: 'bottom' })
        .setLngLat([lng, lat])
        .addTo(window.MapState.map);

    window.MapState.markers['destination'] = marker;

    if (zoomAfter) {
        window.MapState.map.flyTo({
            center: [lng, lat],
            padding: window.getDynamicPadding({ top: 220, bottom: 80 }),
            zoom: zoomAfter,
            duration: 1000
        });
    }
};

// ==========================================
// ROUTE DRAWING
// ==========================================
window.clearRoute = function() {
    if (!window.MapState.map) return;
    try {
        if (window.MapState.map.getLayer('route-line')) window.MapState.map.removeLayer('route-line');
    } catch (e) {}
    try {
        if (window.MapState.map.getSource('route')) window.MapState.map.removeSource('route');
    } catch (e) {}
};

window.drawRoute = function(coords, color) {
    if (!window.MapState.map || !window.MapState.map.isStyleLoaded()) {
        setTimeout(() => window.drawRoute(coords, color), 100);
        return;
    }
    window.clearRoute();
    if (!coords || coords.length < 2) return;

    const formattedCoords = coords.map(c => [c.lng, c.lat]);
    window.MapState.map.addSource('route', {
        type: 'geojson',
        data: {
            type: 'Feature',
            geometry: {
                type: 'LineString',
                coordinates: formattedCoords
            }
        }
    });

    window.MapState.map.addLayer({
        id: 'route-line',
        type: 'line',
        source: 'route',
        paint: {
            'line-color': color || '#C5FF30',
            'line-width': 6,
            'line-opacity': 0.85
        }
    });
};

window.fitRouteBounds = function(padding) {
    if (!window.MapState.map) {
        setTimeout(() => window.fitRouteBounds(padding), 100);
        return;
    }
    const bounds = new maplibregl.LngLatBounds();
    const pickup = window.MapState.markers['pickup'];
    const dest = window.MapState.markers['destination'];
    
    if (pickup) bounds.extend(pickup.getLngLat());
    if (dest) bounds.extend(dest.getLngLat());
    
    if (!bounds.isEmpty()) {
        window.MapState.map.fitBounds(bounds, {
            padding: window.getDynamicPadding(padding || { top: 220, bottom: 320, left: 50, right: 50 }),
            duration: 1200
        });
    }
};

// ==========================================
// SEARCHING SCREEN ANIMATION HELPER
// ==========================================
let searchingRippleMarkers = [];
let searchingCompassMarker = null;

window.startSearchingAnimation = function(lat, lng) {
    if (!window.MapState.map) {
        setTimeout(() => window.startSearchingAnimation(lat, lng), 150);
        return;
    }
    window.stopSearchingAnimation();

    if (!document.getElementById('search-ripple-style')) {
        const styleSheet = document.createElement("style");
        styleSheet.id = 'search-ripple-style';
        styleSheet.innerText = `
            @keyframes ripple {
                0% { transform: scale(0.6); opacity: 0.85; }
                100% { transform: scale(2.0); opacity: 0; }
            }
            .pulse-ripple { animation: ripple 3s infinite ease-out; }
        `;
        document.head.appendChild(styleSheet);
    }

    const rippleContainer = document.createElement('div');
    rippleContainer.style.width = '0px';
    rippleContainer.style.height = '0px';
    rippleContainer.style.position = 'relative';

    const ripple1 = document.createElement('div');
    ripple1.className = 'pulse-ripple';
    ripple1.style.position = 'absolute';
    ripple1.style.width = '240px';
    ripple1.style.height = '240px';
    ripple1.style.borderRadius = '50%';
    ripple1.style.background = 'rgba(16, 185, 129, 0.08)';
    ripple1.style.border = '2px solid rgba(16, 185, 129, 0.15)';
    ripple1.style.left = '-120px';
    ripple1.style.top = '-120px';
    ripple1.style.pointerEvents = 'none';

    const ripple2 = document.createElement('div');
    ripple2.className = 'pulse-ripple';
    ripple2.style.position = 'absolute';
    ripple2.style.width = '240px';
    ripple2.style.height = '240px';
    ripple2.style.borderRadius = '50%';
    ripple2.style.background = 'rgba(16, 185, 129, 0.04)';
    ripple2.style.border = '1px solid rgba(16, 185, 129, 0.08)';
    ripple2.style.left = '-120px';
    ripple2.style.top = '-120px';
    ripple2.style.pointerEvents = 'none';
    ripple2.style.animationDelay = '1.5s';

    rippleContainer.appendChild(ripple1);
    rippleContainer.appendChild(ripple2);

    const rippleMarker = new maplibregl.Marker({ element: rippleContainer })
        .setLngLat([lng, lat])
        .addTo(window.MapState.map);

    searchingRippleMarkers.push(rippleMarker);

    // Custom Compass Arrow Center Marker
    const centerElement = document.createElement('div');
    centerElement.style.width = '32px';
    centerElement.style.height = '32px';
    centerElement.style.borderRadius = '50%';
    centerElement.style.background = '#10B981';
    centerElement.style.border = '3px solid #FFFFFF';
    centerElement.style.boxShadow = '0 4px 12px rgba(0,0,0,0.3)';
    centerElement.style.display = 'flex';
    centerElement.style.alignItems = 'center';
    centerElement.style.justifyContent = 'center';
    centerElement.style.transform = 'rotate(45deg)';

    centerElement.innerHTML = `
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M12 2 L2 22 L12 18 L22 22 L12 2Z" fill="white" stroke="white" stroke-width="2" stroke-linejoin="round"/>
        </svg>
    `;

    searchingCompassMarker = new maplibregl.Marker({ element: centerElement })
        .setLngLat([lng, lat])
        .addTo(window.MapState.map);
};

window.stopSearchingAnimation = function() {
    searchingRippleMarkers.forEach(m => m.remove());
    searchingRippleMarkers = [];
    if (searchingCompassMarker) {
        searchingCompassMarker.remove();
        searchingCompassMarker = null;
    }
};

window.setDestination = function(lat, lng) {
    window.addDestinationMarker(lat, lng);
};

window.updateRoute = function(coordinates) {
    window.drawRoute(coordinates);
};

window.updateRiderLocation = function(lat, lng, avatarUrl, name, vehicleType) {
    window.removeMarker('rider_tracked');
    if (!window.MapState.map) return;
    const el = document.createElement('div');
    el.className = 'rider-tracked-marker';
    el.style.cssText = `
        width: 32px; height: 32px;
        background: #3B82F6;
        border: 2px solid white;
        border-radius: 50%;
        box-shadow: 0 2px 8px rgba(0,0,0,0.2);
    `;
    const m = new maplibregl.Marker({ element: el })
        .setLngLat([lng, lat])
        .addTo(window.MapState.map);
    window.MapState.markers['rider_tracked'] = m;
};

window.zoomIn = function() { if (window.MapState.map) window.MapState.map.zoomIn(); };
window.zoomOut = function() { if (window.MapState.map) window.MapState.map.zoomOut(); };

window.recenterToRider = function() {
    window.MapState.userHasInteracted = false;
    window.autoFollowEnabled = true;
    window.isFollowingRider = true;
    
    if (!window.MapState.map) return;
    
    if (window.MapState.markers['rider_tracked']) {
        window.MapState.map.flyTo({
            center: window.MapState.markers['rider_tracked'].getLngLat(),
            padding: window.getDynamicPadding({ top: 80, bottom: 340 }),
            zoom: 15,
            duration: 900
        });
    } else if (window.MapState.markers['pickup']) {
        window.MapState.map.flyTo({
            center: window.MapState.markers['pickup'].getLngLat(),
            padding: window.getDynamicPadding({ top: 80, bottom: 340 }),
            zoom: 15,
            duration: 900
        });
    }
};

window.recenterToPickup = function() {
    window.MapState.userHasInteracted = false;
    window.autoFollowEnabled = true;
    window.isFollowingRider = false;
    
    if (!window.MapState.map) return;
    
    if (window.MapState.markers['pickup']) {
        window.MapState.map.flyTo({
            center: window.MapState.markers['pickup'].getLngLat(),
            padding: window.getDynamicPadding({ top: 80, bottom: 340 }),
            zoom: 15,
            duration: 900
        });
    } else if (typeof searchingCompassMarker !== 'undefined' && searchingCompassMarker) {
        window.MapState.map.flyTo({
            center: searchingCompassMarker.getLngLat(),
            padding: window.getDynamicPadding({ top: 80, bottom: 340 }),
            zoom: 15,
            duration: 900
        });
    }
};

// ==========================================
// NEARBY RIDERS ANIMATION ENGINE
// ==========================================
window.nearbyRiderMarkers = [];
window.allRidersData = [];
window.activeFilterType = null;
let locationUpdateBuffer = {};
let bufferTimeout = null;

// Interpolate helpers for nearby riders
function coreLerp(start, end, t) {
    return start + (end - start) * t;
}

function coreLerpAngle(a, b, t) {
    let difference = (b - a) % 360;
    if (difference > 180) difference -= 360;
    if (difference < -180) difference += 360;
    return a + difference * t;
}

window.AnimationManager = {
    markers: {}, // id -> { marker, currentLat, currentLng, targetLat, targetLng, currentHeading, targetHeading, name, vehicleType, presenceState }
    loopActive: false,
    performanceMode: 'HIGH',

    register(id, marker, data) {
        this.markers[id] = {
            marker: marker,
            currentLat: data.currentLat,
            currentLng: data.currentLng,
            targetLat: data.targetLat,
            targetLng: data.targetLng,
            currentHeading: data.currentHeading,
            targetHeading: data.targetHeading,
            name: data.name,
            vehicleType: data.vehicleType,
            presenceState: data.presenceState || 'available'
        };
        if (!this.loopActive) {
            this.loopActive = true;
            this.animate();
        }
    },

    unregister(id) {
        if (this.markers[id]) {
            delete this.markers[id];
        }
        if (Object.keys(this.markers).length === 0) {
            this.loopActive = false;
        }
    },

    // Perf fix (WayDrop Phase 2F, F1): true when every registered marker's rendered position and
    // heading are within animate()'s own per-step epsilons of its target -- i.e. another frame
    // would move nothing visible. Reuses the exact 0.000005 deg / 1 deg thresholds animate()
    // already applies below, so "converged" means precisely "animate() has nothing left to do".
    _allConverged() {
        const markers = window.AnimationManager.markers;
        const ids = Object.keys(markers);
        for (let i = 0; i < ids.length; i++) {
            const m = markers[ids[i]];
            if (!m) continue;
            if (Math.abs(m.targetLat - m.currentLat) > 0.000005) return false;
            if (Math.abs(m.targetLng - m.currentLng) > 0.000005) return false;
            if (Math.abs(m.targetHeading - m.currentHeading) > 1) return false;
        }
        return true;
    },

    // Perf fix (WayDrop Phase 2F, F1): re-arm the loop after it has stopped from convergence.
    // Safe to call any number of times -- it only ever starts a loop when one is not already
    // running AND there is something left to animate, so it can never create a second concurrent
    // requestAnimationFrame chain (same guarantee register() gives, and _resumeRiderAnimation()
    // in tracking_engine.js).
    _rearm() {
        const am = window.AnimationManager;
        if (am.loopActive) return;
        if (Object.keys(am.markers).length === 0) return;
        if (am._allConverged()) return;
        am.loopActive = true;
        am.animate();
    },

    animate() {
        if (!window.AnimationManager.loopActive) return;

        const factor = window.AnimationManager.performanceMode === 'HIGH' ? 0.08 : (window.AnimationManager.performanceMode === 'MEDIUM' ? 0.05 : 0.03);
        const fpsInterval = window.AnimationManager.performanceMode === 'HIGH' ? 0 : (window.AnimationManager.performanceMode === 'MEDIUM' ? 33 : 66);
        
        // LngLatBounds.expand() doesn't exist on the bundled maplibre-gl version -- calling it
        // unconditionally threw on every first-marker registration (register() calls animate()
        // synchronously), aborting the AnimationManager loop before it ever scheduled its first
        // requestAnimationFrame. Falls back to the unpadded viewport bounds, which only makes the
        // off-screen-marker culling slightly less generous at the edges, not incorrect.
        const rawBounds = window.MapState.map ? window.MapState.map.getBounds() : null;
        const bounds = rawBounds && typeof rawBounds.expand === 'function' ? rawBounds.expand(0.15) : rawBounds;

        Object.keys(window.AnimationManager.markers).forEach(id => {
            const m = window.AnimationManager.markers[id];
            if (!m || !m.marker) return;

            const pos = [m.currentLng, m.currentLat];
            const isVisible = bounds ? bounds.contains(pos) : true;

            if (!isVisible) {
                m.currentLat = m.targetLat;
                m.currentLng = m.targetLng;
                m.currentHeading = m.targetHeading;
                m.marker.setLngLat([m.currentLng, m.currentLat]);
                return;
            }

            m.currentLat = coreLerp(m.currentLat, m.targetLat, factor);
            m.currentLng = coreLerp(m.currentLng, m.targetLng, factor);
            m.marker.setLngLat([m.currentLng, m.currentLat]);

            const dx = m.targetLng - m.currentLng;
            const dy = m.targetLat - m.currentLat;
            if (Math.abs(dx) > 0.000005 || Math.abs(dy) > 0.000005) {
                m.targetHeading = Math.atan2(dx, dy) * (180 / Math.PI);
            }

            const headingDiff = m.targetHeading - m.currentHeading;
            if (Math.abs(headingDiff) > 1) {
                let step = coreLerpAngle(m.currentHeading, m.targetHeading, factor) - m.currentHeading;
                const maxRotate = 8;
                if (Math.abs(step) > maxRotate) {
                    step = Math.sign(step) * maxRotate;
                }
                m.currentHeading = (m.currentHeading + step) % 360;

                const iconEl = m.marker.getElement().querySelector('.rider-vehicle-icon');
                if (iconEl) {
                    const type = m.vehicleType;
                    const isBike = (type === 'bike' || type === 'bike_ev');
                    const isAuto = (type === 'auto' || type === 'auto_ev');
                    const scale = (isBike || isAuto) ? 'scale(1.3)' : 'scale(1.4)';
                    iconEl.style.transform = `rotate(${m.currentHeading}deg) ${scale}`;
                }
            }
        });

        // Perf fix (WayDrop Phase 2F, F1): every registered marker has visually converged onto its
        // target -- stop scheduling frames instead of redrawing stationary markers forever. Re-armed
        // by register() (new marker) and by _rearm() from applyBufferedUpdates() (existing marker
        // gets a new target). Mirrors the animateActiveRider()/isRiderStateConverged() fix already
        // shipped for the single-rider tracking marker in tracking_engine.js.
        if (window.AnimationManager._allConverged()) {
            window.AnimationManager.loopActive = false;
            return;
        }

        if (fpsInterval > 0) {
            setTimeout(() => {
                requestAnimationFrame(window.AnimationManager.animate);
            }, fpsInterval);
        } else {
            requestAnimationFrame(window.AnimationManager.animate);
        }
    }
};

window.refreshMarkerLOD = function() {
    if (!window.MapState.map || !window.allRidersData) return;
    const zoom = window.MapState.map.getZoom();

    if (zoom < 11) {
        window.trackEvent('cluster_expanded', { count: Object.keys(window.AnimationManager.markers).length });
    }

    Object.keys(window.AnimationManager.markers).forEach(id => {
        const m = window.AnimationManager.markers[id];
        if (!m || !m.marker) return;
        if (typeof window.getVehicleMarkerHTML !== 'function') return;

        const html = window.getVehicleMarkerHTML(m.vehicleType, m.name, zoom, false, m.presenceState);
        
        const el = m.marker.getElement();
        el.innerHTML = html;

        const iconEl = el.querySelector('.rider-vehicle-icon');
        if (iconEl) {
            const type = m.vehicleType;
            const isBike = (type === 'bike' || type === 'bike_ev');
            const isAuto = (type === 'auto' || type === 'auto_ev');
            const scale = (isBike || isAuto) ? 'scale(1.3)' : 'scale(1.4)';
            iconEl.style.transform = `rotate(${m.currentHeading}deg) ${scale}`;
        }
    });
};

window.showNearbyRiders = function(riders, filterType) {
    if (riders !== undefined) window.allRidersData = riders;
    window.activeFilterType = (filterType !== undefined) ? filterType : null;

    if (!window.MapState.map || !window.allRidersData) return;

    locationUpdateBuffer = {};

    const visibleRiders = window.activeFilterType
        ? window.allRidersData.filter(r => r.vehicle_type === window.activeFilterType)
        : window.allRidersData;

    visibleRiders.forEach(rider => {
        if (!rider.current_lng || !rider.current_lat) return;
        locationUpdateBuffer[rider.id] = rider;
    });

    if (!bufferTimeout) {
        bufferTimeout = setTimeout(() => {
            try {
                window.applyBufferedUpdates();
            } catch (e) {
                console.error("[OlaMapCore] Error in applyBufferedUpdates:", e);
            } finally {
                bufferTimeout = null;
            }
        }, 250);
    }
};

window.applyBufferedUpdates = function() {
    const currentRiderIds = new Set();
    const zoom = window.MapState.map ? window.MapState.map.getZoom() : 13;

    const ridersToUpdate = Object.values(locationUpdateBuffer);
    const resolvedCoords = {};
    
    ridersToUpdate.forEach(rider => {
        resolvedCoords[rider.id] = { lat: rider.current_lat, lng: rider.current_lng };
    });

    const visited = new Set();
    for (let i = 0; i < ridersToUpdate.length; i++) {
        const r1 = ridersToUpdate[i];
        if (visited.has(r1.id)) continue;

        const group = [r1.id];
        visited.add(r1.id);

        for (let j = i + 1; j < ridersToUpdate.length; j++) {
            const r2 = ridersToUpdate[j];
            if (visited.has(r2.id)) continue;

            const dLat = r1.current_lat - r2.current_lat;
            const dLng = r1.current_lng - r2.current_lng;
            const dist = Math.sqrt(dLat * dLat + dLng * dLng);

            if (dist < 0.00015) {
                group.push(r2.id);
                visited.add(r2.id);
            }
        }

        if (group.length > 1) {
            let avgLat = 0;
            let avgLng = 0;
            group.forEach(id => {
                avgLat += resolvedCoords[id].lat;
                avgLng += resolvedCoords[id].lng;
            });
            avgLat /= group.length;
            avgLng /= group.length;

            const radius = 0.00010;
            group.forEach((id, idx) => {
                const angle = (idx * 2 * Math.PI) / group.length;
                resolvedCoords[id].lat = avgLat + radius * Math.sin(angle);
                resolvedCoords[id].lng = avgLng + radius * Math.cos(angle);
            });
        }
    }

    ridersToUpdate.forEach(rider => {
        currentRiderIds.add(rider.id.toString());
        const lat = resolvedCoords[rider.id].lat;
        const lng = resolvedCoords[rider.id].lng;

        let mState = window.AnimationManager.markers[rider.id];

        if (!mState) {
            // vehicle_marker_templates.js may not have finished loading yet on this WebView
            // navigation; skip creating this marker and retry on the next refresh cycle rather
            // than throwing and aborting the loop for every other rider in this batch.
            if (typeof window.getVehicleMarkerHTML !== 'function') return;

            const el = document.createElement('div');
            el.className = 'rider-vehicle-marker-wrapper';

            const html = window.getVehicleMarkerHTML(rider.vehicle_type, rider.rider_name || 'Rider', zoom, false, 'available');
            el.innerHTML = html;

            const marker = new maplibregl.Marker({ 
                element: el, 
                anchor: 'center',
                pitchAlignment: 'map',
                rotationAlignment: 'map'
            })
                .setLngLat([lng, lat])
                .addTo(window.MapState.map);

            window.AnimationManager.register(rider.id, marker, {
                currentLat: lat,
                currentLng: lng,
                targetLat: lat,
                targetLng: lng,
                currentHeading: rider.current_heading || 0,
                targetHeading: rider.current_heading || 0,
                name: rider.rider_name || 'Rider',
                vehicleType: rider.vehicle_type,
                presenceState: 'available'
            });
        } else {
            if (mState.vehicleType !== rider.vehicle_type && typeof window.getVehicleMarkerHTML === 'function') {
                mState.vehicleType = rider.vehicle_type;
                const html = window.getVehicleMarkerHTML(rider.vehicle_type, rider.rider_name || 'Rider', zoom, false, 'available');
                mState.marker.getElement().innerHTML = html;
            }

            const dx = lng - mState.currentLng;
            const dy = lat - mState.currentLat;
            const distanceMeters = Math.sqrt(dx*dx + dy*dy) * 111000;

            if (distanceMeters > 150) {
                mState.currentLat = lat;
                mState.currentLng = lng;
            }

            mState.targetLat = lat;
            mState.targetLng = lng;
            mState.targetHeading = rider.current_heading || 0;
            mState.presenceState = 'available';
        }
    });

    Object.keys(window.AnimationManager.markers).forEach(id => {
        if (!currentRiderIds.has(id.toString())) {
            const mState = window.AnimationManager.markers[id];
            if (mState && mState.marker) {
                mState.marker.remove();
            }
            window.AnimationManager.unregister(id);
        }
    });

    // Perf fix (WayDrop Phase 2F, F1): a marker registered above or given a new target must run the
    // animation loop even if it had stopped from a prior convergence. No-op when the loop is
    // already running (or nothing is left to animate).
    window.AnimationManager._rearm();

    if (!window.MapState.userHasInteracted && !window.MapState.firstLoadCompleted && window.MapState.map && ridersToUpdate.length > 0) {
        window.MapState.firstLoadCompleted = true;
        const bounds = new maplibregl.LngLatBounds();
        
        const pickup = window.MapState.markers['pickup'];
        if (pickup) {
            bounds.extend(pickup.getLngLat());
        } else {
            bounds.extend(window.MapState.map.getCenter());
        }
        
        ridersToUpdate.forEach(rider => {
            if (rider.current_lng && rider.current_lat) {
                bounds.extend([rider.current_lng, rider.current_lat]);
            }
        });
        
        window.MapState.map.fitBounds(bounds, {
            padding: window.getDynamicPadding({ top: 80, bottom: 80, left: 60, right: 60 }),
            maxZoom: 15,
            duration: 1000
        });
    }

    locationUpdateBuffer = {};
};

window.filterRidersByType = function(type) {
    window.showNearbyRiders(undefined, type);
};

window.destroyNearbyRidersEngine = function() {
    window.AnimationManager.loopActive = false;
    Object.keys(window.AnimationManager.markers).forEach(id => {
        const mState = window.AnimationManager.markers[id];
        if (mState && mState.marker) {
            mState.marker.remove();
        }
    });
    window.AnimationManager.markers = {};
};
