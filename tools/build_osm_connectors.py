#!/usr/bin/env python3
"""Fetch NoCo OSM highway ways and write a compact connector JSON for BikeNoCo.

Python 3 standard library only. Output: BikeNoCo/Resources/osm_connectors.json
"""

from __future__ import annotations

import json
import math
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

BBOX = (40.33, -105.20, 40.68, -104.95)  # south, west, north, east
OVERPASS_URL = "https://overpass-api.de/api/interpreter"
QUANT = 1e5  # degrees → ints
# Raised from 3 m after the first export landed at ~5.8 MB; still keeps all highway classes.
DP_TOLERANCE_M = 6.0
# Names are omitted from the committed file to stay under the 5 MB budget (classes unchanged).
INCLUDE_NAMES = False
MIN_EDGE_METERS = 4.0
MAX_FILE_BYTES = 5 * 1024 * 1024
EARTH_R = 6_371_000.0

KEEP_HIGHWAYS = {
    "residential",
    "living_street",
    "unclassified",
    "service",
    "tertiary",
    "tertiary_link",
    "secondary",
    "secondary_link",
    "primary",
    "primary_link",
    "cycleway",
    "path",
    "track",
    "footway",
    "pedestrian",
}

DROP_SERVICE = {"parking_aisle", "driveway", "drive-through"}
DROP_HIGHWAYS = {
    "motorway",
    "motorway_link",
    "trunk",
    "trunk_link",
    "construction",
    "proposed",
    "steps",
}

REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_PATH = REPO_ROOT / "BikeNoCo" / "Resources" / "osm_connectors.json"


def meters_per_degree(lat: float) -> tuple[float, float]:
    m_lat = EARTH_R * math.pi / 180.0
    m_lon = m_lat * math.cos(math.radians(lat))
    return m_lat, m_lon


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_R * math.asin(min(1.0, math.sqrt(h)))


def to_local(lat: float, lon: float, origin_lat: float, origin_lon: float) -> tuple[float, float]:
    m_lat, m_lon = meters_per_degree(origin_lat)
    return (lon - origin_lon) * m_lon, (lat - origin_lat) * m_lat


def point_seg_dist(p, a, b) -> float:
    ax, ay = a
    bx, by = b
    px, py = p
    abx, aby = bx - ax, by - ay
    length2 = abx * abx + aby * aby
    if length2 < 1e-18:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * abx + (py - ay) * aby) / length2))
    return math.hypot(px - (ax + t * abx), py - (ay + t * aby))


def douglas_peucker_indices(points_xy: list[tuple[float, float]], keep: set[int], tol: float) -> list[int]:
    n = len(points_xy)
    if n <= 2:
        return list(range(n))
    keep_flags = [False] * n
    keep_flags[0] = True
    keep_flags[n - 1] = True
    for i in keep:
        if 0 <= i < n:
            keep_flags[i] = True

    stack = [(0, n - 1)]
    while stack:
        start, end = stack.pop()
        if end <= start + 1:
            continue
        a = points_xy[start]
        b = points_xy[end]
        max_dist = -1.0
        max_idx = None
        for i in range(start + 1, end):
            d = point_seg_dist(points_xy[i], a, b)
            if d > max_dist:
                max_dist = d
                max_idx = i
        if max_idx is not None and max_dist > tol:
            keep_flags[max_idx] = True
            stack.append((start, max_idx))
            stack.append((max_idx, end))

    return [i for i, flag in enumerate(keep_flags) if flag]


def normalize_highway(tags: dict) -> str | None:
    highway = tags.get("highway")
    if not highway or highway in DROP_HIGHWAYS:
        return None
    if highway not in KEEP_HIGHWAYS:
        return None
    if highway == "service" and tags.get("service") in DROP_SERVICE:
        return None
    if highway in ("footway", "pedestrian"):
        bike = tags.get("bicycle")
        if bike not in ("yes", "designated"):
            return None
    bike = tags.get("bicycle")
    if bike in ("no", "dismount"):
        return None
    access = tags.get("access")
    if access in ("private", "no") and bike not in ("yes", "designated"):
        return None
    # Collapse link variants to their parent class for costing.
    if highway.endswith("_link"):
        return highway[: -len("_link")]
    return highway


def build_overpass_query() -> str:
    south, west, north, east = BBOX
    # Broad highway filter; we refine tags in Python.
    return f"""
[out:json][timeout:300];
(
  way["highway"]({south},{west},{north},{east});
);
out body;
>;
out skel qt;
""".strip()


def fetch_overpass() -> dict:
    query = build_overpass_query()
    data = urllib.parse.urlencode({"data": query}).encode("utf-8")
    request = urllib.request.Request(
        OVERPASS_URL,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": "BikeNoCo/1.0 (connector build)"},
        method="POST",
    )
    print(f"Querying Overpass for bbox {BBOX}…", flush=True)
    try:
        with urllib.request.urlopen(request, timeout=360) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Overpass HTTP {exc.code}: {body[:500]}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"Overpass request failed: {exc}") from exc
    print(f"Downloaded {len(raw) / 1_000_000:.1f} MB raw JSON", flush=True)
    return json.loads(raw.decode("utf-8"))


def main() -> int:
    payload = fetch_overpass()
    elements = payload.get("elements", [])
    osm_timestamp = payload.get("osm3s", {}).get("timestamp_osm_base") or payload.get("generator", "unknown")

    nodes: dict[int, tuple[float, float]] = {}
    ways: list[dict] = []
    for el in elements:
        if el.get("type") == "node":
            nid = el["id"]
            if "lat" in el and "lon" in el:
                nodes[nid] = (float(el["lat"]), float(el["lon"]))
        elif el.get("type") == "way":
            ways.append(el)

    kept_ways: list[dict] = []
    node_use: Counter[int] = Counter()
    for way in ways:
        tags = way.get("tags") or {}
        highway = normalize_highway(tags)
        if highway is None:
            continue
        node_ids = way.get("nodes") or []
        if len(node_ids) < 2:
            continue
        coords = []
        ok = True
        for nid in node_ids:
            if nid not in nodes:
                ok = False
                break
            coords.append(nodes[nid])
        if not ok or len(coords) < 2:
            continue
        is_bridge = 1 if tags.get("bridge") and tags.get("bridge") not in ("no", "false", "0") else 0
        is_tunnel = 1 if tags.get("tunnel") and tags.get("tunnel") not in ("no", "false", "0") else 0
        name = tags.get("name")
        kept = {
            "highway": highway,
            "name": name,
            "bridge": is_bridge,
            "tunnel": is_tunnel,
            "nodes": node_ids,
            "coords": coords,
        }
        kept_ways.append(kept)
        for nid in node_ids:
            node_use[nid] += 1

    # Split at nodes shared by 2+ kept ways (and always keep way endpoints).
    edges_out: list[dict] = []
    origin_lat = (BBOX[0] + BBOX[2]) / 2.0
    origin_lon = (BBOX[1] + BBOX[3]) / 2.0
    class_counts: Counter[str] = Counter()

    for way in kept_ways:
        node_ids = way["nodes"]
        coords = way["coords"]
        split_indices = {0, len(node_ids) - 1}
        for i, nid in enumerate(node_ids):
            if node_use[nid] >= 2:
                split_indices.add(i)
        ordered_splits = sorted(split_indices)

        for s in range(len(ordered_splits) - 1):
            i0 = ordered_splits[s]
            i1 = ordered_splits[s + 1]
            if i1 <= i0:
                continue
            piece_nodes = node_ids[i0 : i1 + 1]
            piece_coords = coords[i0 : i1 + 1]
            if len(piece_coords) < 2:
                continue

            local = [to_local(lat, lon, origin_lat, origin_lon) for lat, lon in piece_coords]
            # Must keep first/last (split endpoints). No other forced keep indices inside piece
            # unless they are also split points — by construction only ends are splits for this piece.
            keep_idx = {0, len(local) - 1}
            simplified_idx = douglas_peucker_indices(local, keep_idx, DP_TOLERANCE_M)
            simp_coords = [piece_coords[i] for i in simplified_idx]
            if len(simp_coords) < 2:
                continue

            length_m = 0.0
            for i in range(1, len(simp_coords)):
                length_m += haversine_m(simp_coords[i - 1], simp_coords[i])
            if length_m < MIN_EDGE_METERS:
                continue

            # Delta-encode at 1e-5 degrees, lat/lon interleaved.
            encoded: list[int] = []
            prev_lat_i = prev_lon_i = 0
            for idx, (lat, lon) in enumerate(simp_coords):
                lat_i = int(round(lat * QUANT))
                lon_i = int(round(lon * QUANT))
                if idx == 0:
                    encoded.extend([lat_i, lon_i])
                else:
                    encoded.extend([lat_i - prev_lat_i, lon_i - prev_lon_i])
                prev_lat_i, prev_lon_i = lat_i, lon_i

            edge = {
                "h": way["highway"],
                "a": piece_nodes[0],
                "z": piece_nodes[-1],
                "c": encoded,
            }
            if INCLUDE_NAMES and way["name"]:
                edge["n"] = way["name"]
            if way["bridge"]:
                edge["b"] = 1
            if way["tunnel"]:
                edge["t"] = 1

            edges_out.append(edge)
            class_counts[way["highway"]] += 1

    doc = {
        "meta": {
            "source": "OpenStreetMap Overpass API",
            "osm_timestamp": osm_timestamp,
            "bbox": {"south": BBOX[0], "west": BBOX[1], "north": BBOX[2], "east": BBOX[3]},
            "attribution": "© OpenStreetMap contributors (ODbL)",
            "quantize": QUANT,
            "douglas_peucker_m": DP_TOLERANCE_M,
        },
        "edges": edges_out,
    }

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(doc, separators=(",", ":"), ensure_ascii=False)
    raw = text.encode("utf-8")
    OUT_PATH.write_bytes(raw)

    size = len(raw)
    print(f"Wrote {OUT_PATH}")
    print(f"Edges: {len(edges_out)}")
    print(f"File size: {size / 1_000_000:.2f} MB ({size} bytes)")
    print("Highway class breakdown:")
    for cls, count in sorted(class_counts.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {cls}: {count}")

    if size > MAX_FILE_BYTES:
        print(f"ERROR: file size {size} exceeds {MAX_FILE_BYTES} byte limit", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
