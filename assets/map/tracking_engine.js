/**
 * Waydrop Ola Maps Tracking Engine
 * API Version: 1.0.0
 */

window.riderMarker = null;
window.activeRiderState = null;
window.lastKnownVehicleType = 'bike';
window.lastKnownHeading = 0;
window.isFallbackActive = false;
window.isFollowingRider = true;

window.pendingMainRoute = null;
window.pendingRiderRoute = null;

// Perf fix (WayDrop Phase G): animateActiveRider() used to call requestAnimationFrame(itself)
// unconditionally forever once started, redrawing the marker every frame for the rest of the trip
// even while the rider was stationary. These two track whether a frame is currently scheduled, so
// the loop can stop once the marker visually converges onto its target, and resume exactly once
// (never double-scheduled) the next time updateRiderLocation() sets a genuinely new target.
window._riderAnimationActive = false;
window._riderAnimationFrameId = null;

// Math Helpers
function trackingLerp(start, end, t) {
    return start + (end - start) * t;
}

function trackingLerpAngle(a, b, t) {
    let difference = (b - a) % 360;
    if (difference > 180) difference -= 360;
    if (difference < -180) difference += 360;
    return a + difference * t;
}

const MODEL_CONFIGS = {
    bike: { modelId: "449314d6b3ed45d29f65c876e7896386", scale: 1, baseRotation: 0 },
    auto: { modelId: "5d3b827310e747a8b5b4079f26ebb221", scale: 1, baseRotation: 0 },
    cab:  { modelId: "ab237b19c503414690dbe78612871754", scale: 1, baseRotation: 0 }
};

// Convergence thresholds reused, not invented: POSITION_CONVERGENCE_DEG is the same "ignore
// micro-jitter" 1.5m precision already used below for incoming GPS updates (dist < 1.5), expressed
// in degrees via the same meters-per-degree constant (111000) this file already uses for that
// check -- tightened slightly (0.3m) since this is deciding when the already-smoothed marker has
// visually settled, not filtering raw GPS noise. HEADING_CONVERGENCE_DEG reuses the exact 0.5
// degree threshold animateActiveRider() already used to decide whether rotation was worth applying.
const POSITION_CONVERGENCE_DEG = 0.3 / 111000;
const HEADING_CONVERGENCE_DEG = 0.5;

function isRiderStateConverged() {
    const s = window.activeRiderState;
    if (!s) return true;
    const latDiff = Math.abs(s.targetLat - s.currentLat);
    const lngDiff = Math.abs(s.targetLng - s.currentLng);
    const headingDiff = Math.abs(s.targetHeading - s.currentHeading);
    return latDiff < POSITION_CONVERGENCE_DEG && lngDiff < POSITION_CONVERGENCE_DEG && headingDiff <= HEADING_CONVERGENCE_DEG;
}

window.animateActiveRider = function() {
    if (!window.activeRiderState || !window.riderMarker) {
        window._riderAnimationActive = false;
        window._riderAnimationFrameId = null;
        return;
    }
    const factor = 0.08;

    window.activeRiderState.currentLat = trackingLerp(window.activeRiderState.currentLat, window.activeRiderState.targetLat, factor);
    window.activeRiderState.currentLng = trackingLerp(window.activeRiderState.currentLng, window.activeRiderState.targetLng, factor);
    window.riderMarker.setLngLat([window.activeRiderState.currentLng, window.activeRiderState.currentLat]);

    const headingDiff = window.activeRiderState.targetHeading - window.activeRiderState.currentHeading;
    if (Math.abs(headingDiff) > 0.5) {
        let step = trackingLerpAngle(window.activeRiderState.currentHeading, window.activeRiderState.targetHeading, factor) - window.activeRiderState.currentHeading;
        const maxRotate = 8;
        if (Math.abs(step) > maxRotate) {
            step = Math.sign(step) * maxRotate;
        }
        window.activeRiderState.currentHeading = (window.activeRiderState.currentHeading + step) % 360;
        window.lastKnownHeading = window.activeRiderState.currentHeading;

        const iconEl = window.riderMarker.getElement().querySelector('.rider-vehicle-icon');
        if (iconEl) {
            const type = window.activeRiderState.vehicleType;
            const isBike = (type === 'bike' || type === 'bike_ev');
            const isAuto = (type === 'auto' || type === 'auto_ev');
            const scale = (isBike || isAuto) ? 'scale(1.3)' : 'scale(1.4)';
            const displayHeading = window.activeRiderState.currentHeading;
            iconEl.style.transform = `rotate(${displayHeading}deg) ${scale}`;
        }
    }

    if (isRiderStateConverged()) {
        // Snap exactly onto the target -- an exponential lerp asymptotically approaches but never
        // exactly equals it -- then stop scheduling further frames. Nothing left to animate until
        // updateRiderLocation() sets a new target and calls window._resumeRiderAnimation() below.
        window.activeRiderState.currentLat = window.activeRiderState.targetLat;
        window.activeRiderState.currentLng = window.activeRiderState.targetLng;
        window.activeRiderState.currentHeading = window.activeRiderState.targetHeading;
        window.riderMarker.setLngLat([window.activeRiderState.currentLng, window.activeRiderState.currentLat]);
        window._riderAnimationActive = false;
        window._riderAnimationFrameId = null;
        return;
    }

    window._riderAnimationFrameId = requestAnimationFrame(window.animateActiveRider);
};

// Perf fix (WayDrop Phase G): the single entry point for (re)starting the animation loop. Safe to
// call any number of times, including while already running or while already converged -- it only
// ever schedules a new requestAnimationFrame chain when one isn't already in flight AND there is
// actually something left to animate, so it can never create a second concurrent loop.
window._resumeRiderAnimation = function() {
    if (window._riderAnimationActive) return;
    if (isRiderStateConverged()) return;
    window._riderAnimationActive = true;
    window.animateActiveRider();
};

window.updateRiderLocation = function(lat, lng, name, image, vehicleType, heading, status, retryCount) {
    if (lat === null || lat === undefined || isNaN(lat) || lng === null || lng === undefined || isNaN(lng)) {
        return;
    }
    retryCount = retryCount || 0;
    if (retryCount > 100) return;

    if (!window.MapState.map || !window.MapState.map.isStyleLoaded()) {
        setTimeout(() => window.updateRiderLocation(lat, lng, name, image, vehicleType, heading, status, retryCount + 1), 200);
        return;
    }

    const isOngoing = (status === 'ongoing' || status === 'picked_up' || status === 'rider_at_drop');
    if (window.MapState.map.getLayer('route-line')) {
        window.MapState.map.setLayoutProperty('route-line', 'visibility', 'none');
    }
    if (window.MapState.map.getLayer('route-shadow')) {
        window.MapState.map.setLayoutProperty('route-shadow', 'visibility', 'none');
    }
    const showRoute = (status !== 'completed' && status !== 'cancelled');
    if (window.MapState.map.getLayer('rider-route-line')) {
        window.MapState.map.setLayoutProperty('rider-route-line', 'visibility', showRoute ? 'visible' : 'none');
    }
    if (window.MapState.map.getLayer('rider-route-shadow')) {
        window.MapState.map.setLayoutProperty('rider-route-shadow', 'visibility', showRoute ? 'visible' : 'none');
    }

    if (vehicleType) window.lastKnownVehicleType = vehicleType;

    const currentType = vehicleType || window.lastKnownVehicleType;

    if (!window.riderMarker) {
        window.isFallbackActive = true;
        const el = document.createElement('div');
        el.className = 'rider-3d-marker-wrapper';
        el.style.cssText = 'display:flex; flex-direction:column; align-items:center; position:relative; overflow:visible;';

        const config = MODEL_CONFIGS[currentType] || MODEL_CONFIGS.bike;

        const container = document.createElement('div');
        container.className = 'rider-3d-container';
        container.style.cssText = `
            width: 55px;
            height: 55px;
            position: relative;
            filter: drop-shadow(0 8px 16px rgba(0,0,0,0.22));
        `;

        const initialHeading = heading || 0;
        const initialOffset = config.baseRotation || 0;

        // Phase 11B: final 3D-rendered transparent PNG assets (3d_bike.png, 3d_auto.png, 3d_car.png)
        // instead of the hand-drawn flat SVG shapes in vehicle_marker_templates.js. Isolated to this
        // active-rider marker only -- getVehicleMarkerHTML()/VEHICLE_REGISTRY (used elsewhere, e.g.
        // nearby-rider browsing markers in ola_map.html) are untouched. `.rider-vehicle-icon` class
        // name is preserved so animateActiveRider()'s heading-rotation querySelector below keeps
        // working unchanged.
        // Size-polish pass: the three source PNGs were cropped to a uniform ~94% content-fill ratio
        // (each had a different amount of transparent canvas padding, so the same object-fit:contain
        // box previously rendered them at different perceived sizes) -- one shared scale now yields
        // equal visual weight across vehicle types instead of the old per-type 1.3/1.4 split.
        const isBike = (currentType === 'bike' || currentType === 'bike_ev');
        const isAuto = (currentType === 'auto' || currentType === 'auto_ev');
        const assetSrc = isBike ? '3d_bike.png' : (isAuto ? '3d_auto.png' : '3d_car.png');
        const scale = 'scale(1.35)';

        const iconEl = document.createElement('img');
        iconEl.className = 'rider-vehicle-icon';
        iconEl.src = assetSrc;
        iconEl.style.cssText = `width:100%; height:100%; object-fit:contain; pointer-events:none; transform: rotate(${(initialHeading + initialOffset) % 360}deg) ${scale};`;
        container.appendChild(iconEl);
        el.appendChild(container);

        if (name) {
            const label = document.createElement('div');
            label.style.cssText = 'background: rgba(15, 23, 42, 0.9); backdrop-filter: blur(8px); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; padding: 2px 8px; margin-top: 4px; box-shadow: 0 4px 12px rgba(0,0,0,0.15); pointer-events: none; white-space: nowrap; z-index: 4;';
            label.innerHTML = `<span style="font-size: 9px; font-weight: 800; color: white; letter-spacing: 0.3px;">${name}</span>`;
            el.appendChild(label);
        }

        window.riderMarker = new maplibregl.Marker({ 
            element: el, 
            anchor: 'center',
            pitchAlignment: 'map',
            rotationAlignment: 'map'
        })
            .setLngLat([lng, lat])
            .addTo(window.MapState.map);

        window.activeRiderState = {
            currentLat: lat,
            currentLng: lng,
            targetLat: lat,
            targetLng: lng,
            currentHeading: heading || config.baseRotation,
            targetHeading: heading || config.baseRotation,
            vehicleType: currentType,
            name: name
        };

        // current === target at creation (marker just snapped to its first position), so this is
        // correctly a no-op until a real subsequent GPS update sets a new target below.
        window._resumeRiderAnimation();
    } else {
        if (currentType && window.activeRiderState.vehicleType !== currentType) {
            window.activeRiderState.vehicleType = currentType;
            window.riderMarker.remove();
            window.riderMarker = null;
            window.updateRiderLocation(lat, lng, name, image, currentType, heading, status);
            return;
        }

        const prevLat = window.activeRiderState.targetLat;
        const prevLng = window.activeRiderState.targetLng;
        const dx = lng - prevLng;
        const dy = lat - prevLat;
        const dist = Math.sqrt(dx*dx + dy*dy) * 111000;

        if (dist < 1.5) {
            // Ignore micro-jitter
            return;
        }

        if (dist > 1000) {
            console.warn("Large location jump detected: " + dist.toFixed(1) + " m");
            window.activeRiderState.currentLat = lat;
            window.activeRiderState.currentLng = lng;
            window.activeRiderState.targetLat = lat;
            window.activeRiderState.targetLng = lng;
            window.riderMarker.setLngLat([lng, lat]);
            window.activeRiderState.interpolationFactor = 0.08;
        } else if (dist > 100) {
            window.activeRiderState.currentLat = lat;
            window.activeRiderState.currentLng = lng;
            window.activeRiderState.targetLat = lat;
            window.activeRiderState.targetLng = lng;
            window.riderMarker.setLngLat([lng, lat]);
            window.activeRiderState.interpolationFactor = 0.08;
        } else if (dist >= 20) {
            window.activeRiderState.targetLat = lat;
            window.activeRiderState.targetLng = lng;
            window.activeRiderState.interpolationFactor = 0.25;
        } else {
            window.activeRiderState.targetLat = lat;
            window.activeRiderState.targetLng = lng;
            window.activeRiderState.interpolationFactor = 0.08;
        }

        let targetHeading = heading;
        if (targetHeading === null || targetHeading === undefined || targetHeading === 0) {
            if (dist > 2.0) {
                targetHeading = Math.atan2(dx, dy) * (180 / Math.PI);
                if (targetHeading < 0) targetHeading += 360;
                window.activeRiderState.targetHeading = targetHeading;
            }
        } else {
            window.activeRiderState.targetHeading = targetHeading;
        }

        // A new target (position and/or heading) may have just been set above -- resume the
        // animation loop if it had already stopped from a prior convergence. No-op if it's already
        // running or if the new target turned out to already match current (e.g. a snap branch).
        window._resumeRiderAnimation();
    }

    // Perf fix (WayDrop Phase 2A): the camera used to easeTo({duration:1000}) on EVERY GPS fix that
    // passed the jitter filter. At the ~1-3 fixes/sec a moving rider produces, each easeTo interrupted
    // and restarted the previous one, so the MapLibre camera animation never completed and its render
    // loop ran continuously -- unnecessary WebView compositing / GPU load. Now the camera only
    // re-centres when the rider has drifted outside a dead-zone around the current map centre, it
    // never starts a new ease while one is already running (isEasing/isMoving guard), and the ease
    // itself is shorter (600ms). The rider MARKER still glides smoothly on every fix via
    // animateActiveRider() above -- only the camera-follow cadence changed. window.isFollowingRider
    // (cleared on user drag in ola_map_core.js, restored by recenterToRider/focusOnRider below) still
    // gates the whole thing exactly as before, so "follow mode" on/off is unchanged.
    if (window.isFollowingRider && !window.MapState.map.isEasing() && !window.MapState.map.isMoving()) {
        const followCentre = window.MapState.map.getCenter();
        const followDx = lng - followCentre.lng;
        const followDy = lat - followCentre.lat;
        const followDistM = Math.sqrt(followDx * followDx + followDy * followDy) * 111000;
        // 45 m dead-zone, expressed via the same 111000 m-per-degree constant this file already uses:
        // comfortably above the 1.5 m jitter floor and the 20 m "small move" threshold above, so
        // ordinary creeping GPS noise never nudges the camera, while a moving rider is always kept
        // well inside the viewport (zoom 15.5 spans several hundred metres).
        const CAMERA_DEADZONE_M = 45;
        if (followDistM > CAMERA_DEADZONE_M) {
            window.MapState.map.easeTo({
                center: [lng, lat],
                zoom: 15.5,
                duration: 600,
                essential: true
            });
        }
    }
};

window.recenterToRider = function() {
    window.isFollowingRider = true;
    if (window.MapState.map && window.riderMarker) {
        window.MapState.map.flyTo({
            center: window.riderMarker.getLngLat(),
            padding: window.getDynamicPadding({ top: 80, bottom: 340 }),
            zoom: 15,
            duration: 900
        });
    } else if (window.MapState.map && window.MapState.markers['pickup']) {
        window.MapState.map.flyTo({
            center: window.MapState.markers['pickup'].getLngLat(),
            padding: window.getDynamicPadding({ top: 80, bottom: 340 }),
            zoom: 15,
            duration: 900
        });
    }
};

window.focusOnRider = function() {
    window.isFollowingRider = true;
    if (!window.MapState.map || !window.riderMarker) return;
    const pos = window.riderMarker.getLngLat();
    window.MapState.map.flyTo({
        center: [pos.lng, pos.lat],
        padding: window.getDynamicPadding({ bottom: 320 }),
        zoom: 16,
        duration: 1000
    });
};

window.showRoute = function() {
    if (!window.MapState.map) return;
    const bounds = new maplibregl.LngLatBounds();
    bounds.extend([window.PICKUP_LNG, window.PICKUP_LAT]);
    bounds.extend([window.DEST_LNG, window.DEST_LAT]);
    if (window.riderMarker) {
        bounds.extend(window.riderMarker.getLngLat());
    }
    window.MapState.map.fitBounds(bounds, {
        padding: window.getDynamicPadding({ top: 80, bottom: 320, left: 50, right: 50 }),
        maxZoom: 16,
        duration: 1000
    });
};

// ==========================================
// DOUBLE-ROUTE LINE DRAWER
// ==========================================
window.updateMainRoute = function(coordinates, retryCount) {
    window.pendingMainRoute = coordinates;
    retryCount = retryCount || 0;
    if (!window.MapState.map || !window.MapState.map.isStyleLoaded()) {
        if (retryCount < 10) {
            setTimeout(() => window.updateMainRoute(coordinates, retryCount + 1), 300);
        }
        return;
    }
    if (!coordinates || !Array.isArray(coordinates) || coordinates.length < 2) return;

    const mainRouteSource = window.MapState.map.getSource('route');
    if (mainRouteSource) {
        mainRouteSource.setData({
            type: 'Feature',
            geometry: {
                type: 'LineString',
                coordinates: coordinates
            }
        });
    } else {
        window.MapState.map.addSource('route', {
            type: 'geojson',
            data: {
                type: 'Feature',
                geometry: {
                    type: 'LineString',
                    coordinates: coordinates
                }
            }
        });
        window.MapState.map.addLayer({
            id: 'route-shadow',
            type: 'line',
            source: 'route',
            layout: {
                'line-join': 'round',
                'line-cap': 'round'
            },
            paint: {
                'line-color': 'rgba(16, 185, 129, 0.15)',
                'line-width': 10
            }
        });
        window.MapState.map.addLayer({
            id: 'route-line',
            type: 'line',
            source: 'route',
            layout: {
                'line-join': 'round',
                'line-cap': 'round'
            },
            paint: {
                'line-color': '#10B981',
                'line-width': 4,
                'line-dasharray': [1, 0]
            }
        });
    }
};

window.updateRiderRoute = function(coordinates, retryCount) {
    window.pendingRiderRoute = coordinates;
    retryCount = retryCount || 0;
    if (!window.MapState.map || !window.MapState.map.isStyleLoaded()) {
        if (retryCount < 10) {
            setTimeout(() => window.updateRiderRoute(coordinates, retryCount + 1), 300);
        }
        return;
    }
    if (!coordinates || !Array.isArray(coordinates) || coordinates.length < 2) return;

    const riderRouteSource = window.MapState.map.getSource('rider-route');
    if (riderRouteSource) {
        riderRouteSource.setData({
            type: 'Feature',
            geometry: {
                type: 'LineString',
                coordinates: coordinates
            }
        });
    } else {
        window.MapState.map.addSource('rider-route', {
            type: 'geojson',
            data: {
                type: 'Feature',
                geometry: {
                    type: 'LineString',
                    coordinates: coordinates
                }
            }
        });
        window.MapState.map.addLayer({
            id: 'rider-route-shadow',
            type: 'line',
            source: 'rider-route',
            paint: {
                'line-color': 'rgba(37, 99, 235, 0.15)',
                'line-width': 10
            }
        });
        window.MapState.map.addLayer({
            id: 'rider-route-line',
            type: 'line',
            source: 'rider-route',
            layout: {
                'line-join': 'round',
                'line-cap': 'round'
            },
            paint: {
                'line-color': '#2563EB',
                'line-width': 5,
                'line-dasharray': [1, 0]
            }
        });
    }
};

window.redrawRouteLines = function() {
    if (!window.MapState.map || !window.MapState.map.isStyleLoaded()) return;

    try { if (window.MapState.map.getLayer('route-line')) window.MapState.map.removeLayer('route-line'); } catch(e){}
    try { if (window.MapState.map.getLayer('route-shadow')) window.MapState.map.removeLayer('route-shadow'); } catch(e){}
    try { if (window.MapState.map.getSource('route')) window.MapState.map.removeSource('route'); } catch(e){}

    try { if (window.MapState.map.getLayer('rider-route-line')) window.MapState.map.removeLayer('rider-route-line'); } catch(e){}
    try { if (window.MapState.map.getLayer('rider-route-shadow')) window.MapState.map.removeLayer('rider-route-shadow'); } catch(e){}
    try { if (window.MapState.map.getSource('rider-route')) window.MapState.map.removeSource('rider-route'); } catch(e){}

    const activeRoute = window.pendingMainRoute || [];
    const activeRiderRoute = window.pendingRiderRoute || [];

    if (activeRoute.length > 0) window.updateMainRoute(activeRoute);
    if (activeRiderRoute.length > 0) window.updateRiderRoute(activeRiderRoute);
};

window.drawRouteAndMarkers = function(pickupLat, pickupLng, destLat, destLng, initialRouteGeometry, initialRiderRouteGeometry, retryCount) {
    retryCount = retryCount || 0;
    if (!window.MapState.map || !window.MapState.map.isStyleLoaded()) {
        if (retryCount < 10) {
            setTimeout(() => window.drawRouteAndMarkers(pickupLat, pickupLng, destLat, destLng, initialRouteGeometry, initialRiderRouteGeometry, retryCount + 1), 300);
        }
        return;
    }
    const pickupEl = document.createElement('div');
    pickupEl.className = 'pickup-pin';
    pickupEl.style.cssText = 'width: 36px; height: 45px; filter: drop-shadow(0px 4px 8px rgba(0,0,0,0.18)); cursor: pointer;';
    pickupEl.innerHTML = `
        <svg viewBox="0 0 24 30" width="36" height="45" xmlns="http://www.w3.org/2000/svg">
            <ellipse cx="12" cy="28" rx="6" ry="2" fill="rgba(0,0,0,0.25)" />
            <path d="M12 2 C6.48 2 2 6.48 2 12 C2 19.5 12 28 12 28 C12 28 22 19.5 22 12 C22 6.48 17.52 2 12 2 Z" fill="#10B981" stroke="#FFFFFF" stroke-width="1.8" />
            <circle cx="12" cy="12" r="4.5" fill="#FFFFFF" />
        </svg>
    `;
    const pickupMarker = new maplibregl.Marker({ element: pickupEl, anchor: 'bottom' })
        .setLngLat([pickupLng, pickupLat]).addTo(window.MapState.map);
    window.MapState.markers['pickup'] = pickupMarker;

    const destEl = document.createElement('div');
    destEl.className = 'dest-pin';
    destEl.style.cssText = 'width: 36px; height: 45px; filter: drop-shadow(0px 4px 8px rgba(0,0,0,0.18)); cursor: pointer;';
    destEl.innerHTML = `
        <svg viewBox="0 0 24 30" width="36" height="45" xmlns="http://www.w3.org/2000/svg">
            <ellipse cx="12" cy="28" rx="6" ry="2" fill="rgba(0,0,0,0.25)" />
            <path d="M12 2 C6.48 2 2 6.48 2 12 C2 19.5 12 28 12 28 C12 28 22 19.5 22 12 C22 6.48 17.52 2 12 2 Z" fill="#EF4444" stroke="#FFFFFF" stroke-width="1.8" />
            <circle cx="12" cy="12" r="4.5" fill="#FFFFFF" />
        </svg>
    `;
    const destMarker = new maplibregl.Marker({ element: destEl, anchor: 'bottom' })
        .setLngLat([destLng, destLat]).addTo(window.MapState.map);
    window.MapState.markers['destination'] = destMarker;

    if (initialRiderRouteGeometry && initialRiderRouteGeometry.length > 0) {
        window.updateRiderRoute(initialRiderRouteGeometry);
    }

    const bounds = new maplibregl.LngLatBounds();
    bounds.extend([pickupLng, pickupLat]);
    bounds.extend([destLng, destLat]);
    window.MapState.map.fitBounds(bounds, { padding: { top: 80, bottom: 340, left: 50, right: 50 }, maxZoom: 16 });
};

window.destroyTrackingEngine = function() {
    if (window._riderAnimationFrameId !== null && typeof cancelAnimationFrame === 'function') {
        cancelAnimationFrame(window._riderAnimationFrameId);
    }
    window._riderAnimationFrameId = null;
    window._riderAnimationActive = false;
    if (window.riderMarker) {
        window.riderMarker.remove();
        window.riderMarker = null;
    }
    window.activeRiderState = null;
    window.isFollowingRider = true;
    window.pendingMainRoute = null;
    window.pendingRiderRoute = null;
};
