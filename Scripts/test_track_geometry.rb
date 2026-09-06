# frozen_string_literal: true

# Pins how much of the bundled track this app can actually draw, and how much of what it draws
# holds together.
#
# `MetroTrackGeometry` slices a line's OSM ways into one polyline per hop, and
# `BundledMetroRouteProvider+RouteAssembly` concatenates a leg's hops into a single `MKPolyline`.
# Two numbers decide whether a drawn route is honest:
#
#   1. **Chord hops** — pairs with no usable stretch of track between them, drawn as a straight
#      line. Every one of these is a rider being shown a shape the train does not follow.
#   2. **Join gaps** — the distance between where hop *i* ends and hop *i+1* begins. `MKPolyline`
#      draws a straight segment across any gap, so a discontinuous join is the same lie, arriving
#      in the middle of a leg where it is harder to notice.
#
# Both used to be far worse than anyone had counted. Resolving each hop independently let two
# consecutive hops put their shared station on two different ways: 2,012 of 7,612 joins were
# discontinuous, 26 by more than 50 m, the worst an 823 m leap through 三重國小. And an arc-length
# floor measured against the wrong quantity discarded six real hops, among them 金鐘 → 中環.
#
# This file is a **reference implementation** of the shipped resolver, run over the real packs. It
# exists because there is no Xcode test target and no other way to hold these numbers still. It has
# to be kept in step with `MetroTrackGeometry` by hand; when the Swift changes, change this and
# say what moved. Distances here are haversine where Swift uses `CLLocation`, so the counts can
# differ by one or two — the pins carry a little headroom for that and no more.

require "minitest/autorun"
require "json"

ROOT = File.expand_path("..", __dir__)
NETWORKS = File.join(ROOT, "Just-Go/Resources/MetroNetworks")

module TrackGeometry
  EARTH = 6_371_008.8
  CANDIDATE_DISTANCE_CAP = 900.0
  CANDIDATE_LIMIT = 4
  CANDIDATE_SEPARATION = 100.0
  SEAM_TOLERANCE = 50.0
  SEAM_WEIGHT = 12.0

  module_function

  def distance(a, b)
    lat1 = a[0] * Math::PI / 180
    lat2 = b[0] * Math::PI / 180
    h = Math.sin((lat2 - lat1) / 2)**2 +
        Math.cos(lat1) * Math.cos(lat2) * Math.sin(((b[1] - a[1]) * Math::PI / 180) / 2)**2
    2 * EARTH * Math.asin([1.0, Math.sqrt(h)].min)
  end

  # Every local minimum of the station-to-track distance, nearest first, one per pass of the way.
  def projections(coordinate, points, cumulative)
    return [] if points.size < 2

    per_segment = []
    (0...(points.size - 1)).each do |i|
      a = points[i]
      b = points[i + 1]
      m_lon = 111_320.0 * Math.cos(a[0] * Math::PI / 180)
      m_lat = 110_540.0
      ax = a[1] * m_lon
      ay = a[0] * m_lat
      bx = b[1] * m_lon
      by = b[0] * m_lat
      px = coordinate[1] * m_lon
      py = coordinate[0] * m_lat
      dx = bx - ax
      dy = by - ay
      length2 = (dx * dx) + (dy * dy)
      t = length2.zero? ? 0.0 : [1.0, [0.0, (((px - ax) * dx) + ((py - ay) * dy)) / length2].max].min
      projected = [(ay + (t * dy)) / m_lat, (ax + (t * dx)) / m_lon]
      per_segment << {
        point: projected,
        distance: distance(coordinate, projected),
        offset: cumulative[i] + (t * (cumulative[i + 1] - cumulative[i]))
      }
    end

    minima = []
    per_segment.each_with_index do |candidate, i|
      previous = i.positive? ? per_segment[i - 1][:distance] : Float::INFINITY
      following = i < per_segment.size - 1 ? per_segment[i + 1][:distance] : Float::INFINITY
      next unless candidate[:distance] <= previous && candidate[:distance] <= following
      next unless candidate[:distance] <= CANDIDATE_DISTANCE_CAP

      minima << candidate
    end
    if minima.empty?
      nearest = per_segment.min_by { |c| c[:distance] }
      minima = [nearest] if nearest && nearest[:distance] <= CANDIDATE_DISTANCE_CAP
    end

    kept = []
    minima.sort_by { |c| c[:distance] }.each do |candidate|
      next if kept.any? { |k| (k[:offset] - candidate[:offset]).abs < CANDIDATE_SEPARATION }

      kept << candidate
      break if kept.size == CANDIDATE_LIMIT
    end
    kept
  end

  def slice(points, cumulative, from, to)
    total = cumulative[-1]
    ring = points.size >= 3 && distance(points[0], points[-1]) < 5
    low = [from[:offset], to[:offset]].min
    high = [from[:offset], to[:offset]].max
    reversed = from[:offset] > to[:offset]
    low_point = reversed ? to[:point] : from[:point]
    high_point = reversed ? from[:point] : to[:point]

    if !ring || (high - low) <= total - (high - low)
      result = [low_point]
      points.each_index { |i| result << points[i] if cumulative[i] > low && cumulative[i] < high }
      result << high_point
    else
      result = [high_point]
      points.each_index { |i| result << points[i] if cumulative[i] > high }
      points.each_index do |i|
        next unless cumulative[i] < low
        next if result.last && distance(result.last, points[i]) < 1

        result << points[i]
      end
      result << low_point
    end
    result.reverse! if reversed
    result
  end

  def arc_length(coordinates)
    total = 0.0
    (1...coordinates.size).each { |i| total += distance(coordinates[i - 1], coordinates[i]) }
    total
  end

  def deduplicated(coordinates)
    joined = []
    coordinates.each { |p| joined << p if joined.empty? || distance(joined.last, p) >= 1 }
    joined
  end

  def prepare(paths)
    paths.map do |points|
      next nil if points.size < 2

      cumulative = [0.0]
      (1...points.size).each { |i| cumulative << cumulative[i - 1] + distance(points[i - 1], points[i]) }
      [points, cumulative]
    end.compact
  end

  # Continuity first, then fit.
  def prefers?(score, seam, other_score, other_seam)
    joins = seam <= SEAM_TOLERANCE
    other_joins = other_seam <= SEAM_TOLERANCE
    return joins if joins != other_joins

    score < other_score
  end

  def hop(from, to, paths, anchor)
    separation = distance(from, to)
    ceiling = [2.5 * separation, separation + 1_500].max
    floor = 0.75 * separation
    best = nil
    best_fallback = nil

    paths.each_with_index do |(points, cumulative), path_index|
      if anchor && anchor[0] == path_index
        from_candidates = [anchor[1]]
      else
        from_candidates = projections(from, points, cumulative)
        if anchor
          projections(anchor[1][:point], points, cumulative).each do |carried|
            next if from_candidates.any? { |c| (c[:offset] - carried[:offset]).abs < CANDIDATE_SEPARATION }

            from_candidates << carried
          end
        end
      end
      to_candidates = projections(to, points, cumulative)
      next if from_candidates.empty? || to_candidates.empty?

      from_candidates.each do |f|
        to_candidates.each do |t|
          next_anchor = [path_index, t]
          entry_seam = anchor ? distance(anchor[1][:point], f[:point]) : 0.0
          off_track = 3 * (f[:distance] + t[:distance])

          fallback_score = off_track + (SEAM_WEIGHT * entry_seam)
          if best_fallback.nil? ||
             prefers?(fallback_score, entry_seam, best_fallback[0], best_fallback[1])
            best_fallback = [fallback_score, entry_seam, [f[:point], t[:point]], next_anchor, :chord]
          end

          candidate = slice(points, cumulative, f, t)
          next if candidate.size < 2

          arc = arc_length(candidate)
          next unless arc <= ceiling
          next unless arc + f[:distance] + t[:distance] >= floor

          joined = deduplicated(candidate)
          next if joined.size < 2

          head = distance(joined.first, from) <= distance(joined.last, from) ? joined.first : joined.last
          seam = anchor ? distance(anchor[1][:point], head) : 0.0
          score = arc + off_track + (SEAM_WEIGHT * seam)
          best = [score, seam, joined, next_anchor, :track] if best.nil? || prefers?(score, seam, best[0], best[1])
        end
      end
    end

    chosen = best || best_fallback
    return [[from, to], nil, :chord] if chosen.nil?

    geometry = chosen[2]
    geometry = geometry.reverse if distance(geometry.first, from) > distance(geometry.last, from)
    [geometry, chosen[3], chosen[4]]
  end

  def resolve_pattern(coordinates, paths)
    anchor = nil
    coordinates.each_cons(2).map do |from, to|
      geometry, next_anchor, kind = hop(from, to, paths, anchor)
      anchor = next_anchor
      [geometry, kind]
    end
  end
end

# Walks every bundled pack once and totals both measures.
def measure_bundled_track
  hops = 0
  chords = 0
  gaps = []

  Dir[File.join(NETWORKS, "*.json")].sort.each do |file|
    pack = JSON.parse(File.read(file, encoding: "UTF-8"))
    stations = {}
    pack["stations"].each { |s| stations[s["id"]] = [s["latitude"], s["longitude"]] }

    pack["lines"].each do |line|
      paths = (line["paths"] || []).map { |path| path.map { |c| [c["latitude"], c["longitude"]] } }
      next if paths.empty?

      prepared = TrackGeometry.prepare(paths)
      next if prepared.empty?

      (line["servicePatterns"] || []).each do |pattern|
        coordinates = pattern.map { |id| stations[id] }
        next if coordinates.any?(&:nil?) || coordinates.size < 2

        previous = nil
        TrackGeometry.resolve_pattern(coordinates, prepared).each do |geometry, kind|
          hops += 1
          chords += 1 if kind == :chord
          gaps << TrackGeometry.distance(previous, geometry.first) if previous
          previous = geometry.last
        end
      end
    end
  end

  { hops: hops, chords: chords, gaps: gaps }
end

MEASURED = measure_bundled_track

class TrackGeometryTest < Minitest::Test
  def test_the_pack_set_has_not_silently_shrunk
    # The denominator for everything below. If a pack is added or dropped this moves, and the
    # counts underneath it have to be re-read rather than merely re-passed.
    assert_equal 8_015, MEASURED[:hops], "bundled hop count changed; re-read the pins below"
  end

  def test_almost_every_hop_draws_real_track
    # 9 with the shipped resolver. These are hops where no way on the line reaches both stations:
    # 南口 → 八达岭 and 康庄 → 沙城 on the S2 line, 清河 → 昌平北 on 怀密线, 馬場 → 沙田, and four
    # tram pairs. Each is drawn as a straight line, which is the honest rendering of "no track
    # here", not a bug to be papered over.
    assert_operator MEASURED[:chords], :<=, 11,
                    "more hops lost their track geometry (was 9 of 8,015)"
  end

  def test_legs_hold_together_at_their_joins
    gaps = MEASURED[:gaps]
    # A leg is one polyline, so a join gap is drawn as a straight segment through the station.
    # Under 1 m is a rounding artefact of two projections onto the same point.
    assert_operator gaps.count { |g| g > 1 }, :<=, 90,
                    "more joins came apart (was 75 of 7,612)"
    # The visible ones. 17 remain, all of them OSM ways that genuinely do not meet near the shared
    # station; closing those would mean drawing track the train does not run on.
    assert_operator gaps.count { |g| g > 50 }, :<=, 20,
                    "more joins broke visibly (was 17 of 7,612)"
  end

  def test_the_worst_join_has_not_got_worse
    assert_operator MEASURED[:gaps].max, :<=, 900,
                    "the widest join gap grew (was 772 m, at 大橋頭 on 台北捷運中和新蘆線)"
  end
end
