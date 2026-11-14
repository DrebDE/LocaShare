/**
 * LocaShare Interactive Map Controller
 *
 * Renders an interactive Web Mercator (EPSG:3857) map with:
 *   1. Local Privacy Grid mode (zero third-party network requests; coordinate graticules & scale bar).
 *   2. Optional OpenStreetMap raster street tiles (https://tile.openstreetmap.org/{z}/{x}/{y}.png)
 *      with explicit user control and OSM attribution compliance.
 *   3. Accurate meter-scaled GPS accuracy circles, multi-device markers, pan/zoom, and device centering.
 */
(function (global) {
    'use strict';

    var TILE_SIZE = 256;
    var MIN_ZOOM = 2;
    var MAX_ZOOM = 18;
    var EARTH_RADIUS_M = 6378137;

    function clamp(val, min, max) {
        return Math.max(min, Math.min(max, val));
    }

    function latLngToWorldPx(lat, lng, zoom) {
        var scale = TILE_SIZE * Math.pow(2, zoom);
        var clampedLat = clamp(lat, -85.05112878, 85.05112878);
        var x = ((lng + 180) / 360) * scale;
        var sinLat = Math.sin((clampedLat * Math.PI) / 180);
        var y = (0.5 - Math.log((1 + sinLat) / (1 - sinLat)) / (4 * Math.PI)) * scale;
        return { x: x, y: y };
    }

    function worldPxToLatLng(x, y, zoom) {
        var scale = TILE_SIZE * Math.pow(2, zoom);
        var lng = (x / scale) * 360 - 180;
        var n = Math.PI - (2 * Math.PI * y) / scale;
        var lat = (180 / Math.PI) * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)));
        return {
            lat: clamp(lat, -85.05112878, 85.05112878),
            lng: ((((lng + 180) % 360) + 360) % 360) - 180
        };
    }

    function metersPerPixel(lat, zoom) {
        var clampedLat = clamp(lat, -85.05112878, 85.05112878);
        return (Math.cos((clampedLat * Math.PI) / 180) * 2 * Math.PI * EARTH_RADIUS_M) / (TILE_SIZE * Math.pow(2, zoom));
    }

    function LocaShareMap(options) {
        this.viewport = options.viewport;
        this.canvas = options.canvas;
        this.markersLayer = options.markersLayer;
        this.onSelectDevice = options.onSelectDevice || function () {};

        this.ctx = this.canvas.getContext('2d');
        this.centerLat = 37.7749;
        this.centerLng = -122.4194;
        this.zoom = 13;
        this.osmTilesEnabled = false;
        this.tileCache = {};

        this.devices = [];
        this.selectedDeviceId = null;
        this.hasAutoCentered = false;

        this.isDragging = false;
        this.dragStartX = 0;
        this.dragStartY = 0;
        this.dragStartWorld = null;

        this._bindEvents();
        this.resize();
    }

    LocaShareMap.prototype._bindEvents = function () {
        var self = this;

        window.addEventListener('resize', function () {
            self.resize();
        });

        this.viewport.addEventListener('mousedown', function (e) {
            if (e.button !== 0 || e.target.closest('.map-controls') || e.target.closest('.map-marker')) {
                return;
            }
            self.isDragging = true;
            self.dragStartX = e.clientX;
            self.dragStartY = e.clientY;
            self.dragStartWorld = latLngToWorldPx(self.centerLat, self.centerLng, self.zoom);
        });

        window.addEventListener('mousemove', function (e) {
            if (!self.isDragging || !self.dragStartWorld) {
                return;
            }
            var dx = e.clientX - self.dragStartX;
            var dy = e.clientY - self.dragStartY;
            var nextWorldX = self.dragStartWorld.x - dx;
            var nextWorldY = self.dragStartWorld.y - dy;
            var nextCenter = worldPxToLatLng(nextWorldX, nextWorldY, self.zoom);
            self.centerLat = nextCenter.lat;
            self.centerLng = nextCenter.lng;
            self.render();
        });

        window.addEventListener('mouseup', function () {
            self.isDragging = false;
            self.dragStartWorld = null;
        });

        this.viewport.addEventListener('wheel', function (e) {
            e.preventDefault();
            var delta = e.deltaY < 0 ? 1 : -1;
            self.setZoom(self.zoom + delta);
        }, { passive: false });
    };

    LocaShareMap.prototype.resize = function () {
        if (!this.viewport || !this.canvas) {
            return;
        }
        var rect = this.viewport.getBoundingClientRect();
        var dpr = window.devicePixelRatio || 1;
        this.width = Math.max(200, Math.floor(rect.width));
        this.height = Math.max(200, Math.floor(rect.height));
        this.canvas.width = this.width * dpr;
        this.canvas.height = this.height * dpr;
        this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        this.render();
    };

    LocaShareMap.prototype.setOsmTilesEnabled = function (enabled) {
        this.osmTilesEnabled = Boolean(enabled);
        this.render();
    };

    LocaShareMap.prototype.setZoom = function (newZoom) {
        this.zoom = clamp(Math.round(newZoom), MIN_ZOOM, MAX_ZOOM);
        this.render();
    };

    LocaShareMap.prototype.setDevices = function (devices, selectedDeviceId) {
        this.devices = Array.isArray(devices) ? devices : [];
        this.selectedDeviceId = selectedDeviceId || null;

        var withLoc = this.devices.filter(function (d) {
            return d.has_location && d.location && typeof d.location.latitude === 'number' && typeof d.location.longitude === 'number';
        });

        if (!this.hasAutoCentered && withLoc.length > 0) {
            this.hasAutoCentered = true;
            if (withLoc.length === 1) {
                this.centerLat = withLoc[0].location.latitude;
                this.centerLng = withLoc[0].location.longitude;
                this.zoom = 15;
            } else {
                this.fitAll();
                return;
            }
        }

        this.render();
    };

    LocaShareMap.prototype.centerOnDevice = function (deviceId, targetZoom) {
        var target = null;
        for (var i = 0; i < this.devices.length; i++) {
            if (this.devices[i].device_id === deviceId) {
                target = this.devices[i];
                break;
            }
        }
        if (target && target.has_location && target.location) {
            this.centerLat = target.location.latitude;
            this.centerLng = target.location.longitude;
            if (typeof targetZoom === 'number') {
                this.zoom = clamp(targetZoom, MIN_ZOOM, MAX_ZOOM);
            } else if (this.zoom < 14) {
                this.zoom = 15;
            }
            this.render();
            return true;
        }
        return false;
    };

    LocaShareMap.prototype.fitAll = function () {
        var withLoc = this.devices.filter(function (d) {
            return d.has_location && d.location;
        });
        if (withLoc.length === 0) {
            this.render();
            return;
        }
        if (withLoc.length === 1) {
            this.centerLat = withLoc[0].location.latitude;
            this.centerLng = withLoc[0].location.longitude;
            this.zoom = 15;
            this.render();
            return;
        }

        var minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
        withLoc.forEach(function (d) {
            var lat = d.location.latitude;
            var lng = d.location.longitude;
            if (lat < minLat) minLat = lat;
            if (lat > maxLat) maxLat = lat;
            if (lng < minLng) minLng = lng;
            if (lng > maxLng) maxLng = lng;
        });

        this.centerLat = (minLat + maxLat) / 2;
        this.centerLng = (minLng + maxLng) / 2;

        for (var z = 16; z >= MIN_ZOOM; z--) {
            var p1 = latLngToWorldPx(maxLat, minLng, z);
            var p2 = latLngToWorldPx(minLat, maxLng, z);
            if (Math.abs(p2.x - p1.x) < this.width * 0.72 && Math.abs(p2.y - p1.y) < this.height * 0.72) {
                this.zoom = z;
                break;
            }
        }
        this.render();
    };

    LocaShareMap.prototype._getTileImage = function (z, x, y) {
        var maxTile = Math.pow(2, z);
        var wrappedX = ((x % maxTile) + maxTile) % maxTile;
        if (y < 0 || y >= maxTile) {
            return null;
        }
        var key = z + '/' + wrappedX + '/' + y;
        if (this.tileCache[key]) {
            return this.tileCache[key];
        }
        var self = this;
        var img = new Image();
        img.crossOrigin = 'anonymous';
        var entry = { img: img, loaded: false, failed: false };
        this.tileCache[key] = entry;

        img.onload = function () {
            entry.loaded = true;
            self.render();
        };
        img.onerror = function () {
            entry.failed = true;
        };
        img.src = 'https://tile.openstreetmap.org/' + key + '.png';
        return entry;
    };

    LocaShareMap.prototype.render = function () {
        if (!this.ctx || !this.width || !this.height) {
            return;
        }

        var ctx = this.ctx;
        var w = this.width;
        var h = this.height;
        var z = this.zoom;

        ctx.clearRect(0, 0, w, h);

        // Background
        ctx.fillStyle = '#0b1325';
        ctx.fillRect(0, 0, w, h);

        var centerWorld = latLngToWorldPx(this.centerLat, this.centerLng, z);
        var topLeftWorldX = centerWorld.x - w / 2;
        var topLeftWorldY = centerWorld.y - h / 2;

        // 1. Optional OpenStreetMap raster tiles
        if (this.osmTilesEnabled) {
            var startTileX = Math.floor(topLeftWorldX / TILE_SIZE);
            var endTileX = Math.floor((topLeftWorldX + w) / TILE_SIZE);
            var startTileY = Math.floor(topLeftWorldY / TILE_SIZE);
            var endTileY = Math.floor((topLeftWorldY + h) / TILE_SIZE);

            for (var tx = startTileX; tx <= endTileX; tx++) {
                for (var ty = startTileY; ty <= endTileY; ty++) {
                    var tileEntry = this._getTileImage(z, tx, ty);
                    if (tileEntry && tileEntry.loaded) {
                        var drawX = Math.floor(tx * TILE_SIZE - topLeftWorldX);
                        var drawY = Math.floor(ty * TILE_SIZE - topLeftWorldY);
                        ctx.drawImage(tileEntry.img, drawX, drawY, TILE_SIZE, TILE_SIZE);
                    }
                }
            }
        }

        // 2. Coordinate Graticule Grid (always visible in Privacy Grid mode, subtle when tiles loaded)
        this._drawGraticule(ctx, w, h, z, topLeftWorldX, topLeftWorldY);

        // 3. Draw Accuracy Circles for devices with location fixes
        var self = this;
        this.devices.forEach(function (dev) {
            if (!dev.has_location || !dev.location) {
                return;
            }
            var loc = dev.location;
            var pt = latLngToWorldPx(loc.latitude, loc.longitude, z);
            var screenX = pt.x - topLeftWorldX;
            var screenY = pt.y - topLeftWorldY;

            if (typeof loc.accuracy === 'number' && loc.accuracy > 0) {
                var mpp = metersPerPixel(loc.latitude, z);
                var radiusPx = clamp(loc.accuracy / mpp, 10, Math.max(w, h));
                ctx.save();
                ctx.beginPath();
                ctx.arc(screenX, screenY, radiusPx, 0, Math.PI * 2);
                var isStale = Boolean(dev.is_location_stale);
                var isSelected = (dev.device_id === self.selectedDeviceId);
                ctx.fillStyle = isStale
                    ? 'rgba(245, 158, 11, 0.14)'
                    : (isSelected ? 'rgba(14, 165, 233, 0.20)' : 'rgba(16, 185, 129, 0.15)');
                ctx.fill();
                ctx.lineWidth = isSelected ? 2 : 1.25;
                ctx.strokeStyle = isStale
                    ? 'rgba(245, 158, 11, 0.65)'
                    : (isSelected ? 'rgba(56, 189, 248, 0.85)' : 'rgba(16, 185, 129, 0.65)');
                ctx.stroke();
                ctx.restore();
            }
        });

        // 4. Draw Center Crosshair & Scale Bar
        this._drawHud(ctx, w, h, z);

        // 5. Render interactive DOM markers
        this._renderDomMarkers(topLeftWorldX, topLeftWorldY);
    };

    LocaShareMap.prototype._drawGraticule = function (ctx, w, h, z, topLeftWorldX, topLeftWorldY) {
        var stepDeg = 10;
        if (z >= 15) stepDeg = 0.005;
        else if (z >= 13) stepDeg = 0.02;
        else if (z >= 11) stepDeg = 0.1;
        else if (z >= 8) stepDeg = 0.5;
        else if (z >= 5) stepDeg = 2;

        var nw = worldPxToLatLng(topLeftWorldX, topLeftWorldY, z);
        var se = worldPxToLatLng(topLeftWorldX + w, topLeftWorldY + h, z);

        ctx.save();
        ctx.strokeStyle = this.osmTilesEnabled ? 'rgba(15, 23, 42, 0.18)' : 'rgba(56, 189, 248, 0.14)';
        ctx.fillStyle = this.osmTilesEnabled ? 'rgba(15, 23, 42, 0.72)' : 'rgba(148, 163, 184, 0.65)';
        ctx.lineWidth = 1;
        ctx.font = '11px ui-monospace, monospace';

        var startLng = Math.floor(nw.lng / stepDeg) * stepDeg;
        for (var lng = startLng; lng <= se.lng + stepDeg; lng += stepDeg) {
            var px = latLngToWorldPx(0, lng, z).x - topLeftWorldX;
            if (px >= 0 && px <= w) {
                ctx.beginPath();
                ctx.moveTo(px, 0);
                ctx.lineTo(px, h);
                ctx.stroke();
                if (!this.osmTilesEnabled) {
                    ctx.fillText(lng.toFixed(stepDeg < 0.1 ? 3 : 1) + '°', px + 4, 14);
                }
            }
        }

        var startLat = Math.floor(se.lat / stepDeg) * stepDeg;
        for (var lat = startLat; lat <= nw.lat + stepDeg; lat += stepDeg) {
            var py = latLngToWorldPx(lat, 0, z).y - topLeftWorldY;
            if (py >= 0 && py <= h) {
                ctx.beginPath();
                ctx.moveTo(0, py);
                ctx.lineTo(w, py);
                ctx.stroke();
                if (!this.osmTilesEnabled) {
                    ctx.fillText(lat.toFixed(stepDeg < 0.1 ? 3 : 1) + '°', 6, py - 4);
                }
            }
        }
        ctx.restore();
    };

    LocaShareMap.prototype._drawHud = function (ctx, w, h, z) {
        var mpp = metersPerPixel(this.centerLat, z);
        var targetPx = 100;
        var rawMeters = mpp * targetPx;
        var niceSteps = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000, 500000];
        var chosenMeters = niceSteps[0];
        for (var i = 0; i < niceSteps.length; i++) {
            if (niceSteps[i] <= rawMeters) {
                chosenMeters = niceSteps[i];
            }
        }
        var barPx = Math.round(chosenMeters / mpp);
        var label = chosenMeters >= 1000 ? (chosenMeters / 1000) + ' km' : chosenMeters + ' m';

        ctx.save();
        var boxX = w - barPx - 24;
        var boxY = h - 34;
        ctx.fillStyle = 'rgba(15, 23, 42, 0.82)';
        ctx.fillRect(boxX - 8, boxY - 6, barPx + 16, 26);
        ctx.strokeStyle = '#94a3b8';
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.moveTo(boxX, boxY + 8);
        ctx.lineTo(boxX, boxY + 13);
        ctx.lineTo(boxX + barPx, boxY + 13);
        ctx.lineTo(boxX + barPx, boxY + 8);
        ctx.stroke();

        ctx.fillStyle = '#e2e8f0';
        ctx.font = '11px -apple-system, BlinkMacSystemFont, sans-serif';
        ctx.fillText(label + ' · z' + z, boxX + 4, boxY + 6);
        ctx.restore();
    };

    LocaShareMap.prototype._renderDomMarkers = function (topLeftWorldX, topLeftWorldY) {
        if (!this.markersLayer) {
            return;
        }
        this.markersLayer.innerHTML = '';

        var self = this;
        this.devices.forEach(function (dev) {
            if (!dev.has_location || !dev.location) {
                return;
            }
            var pt = latLngToWorldPx(dev.location.latitude, dev.location.longitude, self.zoom);
            var sx = pt.x - topLeftWorldX;
            var sy = pt.y - topLeftWorldY;

            if (sx < -60 || sx > self.width + 60 || sy < -60 || sy > self.height + 60) {
                return;
            }

            var marker = document.createElement('div');
            var classes = ['map-marker'];
            if (dev.device_id === self.selectedDeviceId) {
                classes.push('selected');
            }
            if (!dev.is_online) {
                classes.push('offline');
            } else if (dev.is_location_stale) {
                classes.push('stale');
            }
            marker.className = classes.join(' ');
            marker.style.left = Math.round(sx) + 'px';
            marker.style.top = Math.round(sy) + 'px';
            marker.setAttribute('data-device-id', dev.device_id);

            var pin = document.createElement('div');
            pin.className = 'marker-pin';
            marker.appendChild(pin);

            var label = document.createElement('div');
            label.className = 'marker-label';
            var stateSuffix = dev.is_location_stale ? ' (Stale Fix)' : (!dev.is_online ? ' (Offline)' : '');
            label.textContent = dev.device_name + stateSuffix;
            marker.appendChild(label);

            marker.addEventListener('click', function (e) {
                e.stopPropagation();
                self.onSelectDevice(dev.device_id, true);
            });

            self.markersLayer.appendChild(marker);
        });
    };

    global.LocaShareMap = LocaShareMap;
})(window);
