'use strict';

// Date and shading logic for the day picker and the timeline's range selection.
// No DOM here, so `swift test` can run it in JavaScriptCore. Months are 0-based,
// like Date.

const HEAT_HOURS = [3, 6, 9, 12];   // each value starts the next shade

/// 0 means nothing tracked; 1-5 are the shades, lightest for the most time.
function heatLevel(seconds) {
  if (seconds <= 0) return 0;
  return 1 + HEAT_HOURS.filter((h) => seconds >= h * 3600).length;
}

/// One entry per grid cell, Sunday first: nulls pad the first week, then the
/// month's day numbers.
function monthCells(year, month) {
  const pad = new Date(year, month, 1).getDay();
  const days = new Date(year, month + 1, 0).getDate();
  return [...Array(pad).fill(null), ...Array.from({ length: days }, (_, i) => i + 1)];
}

/// Same format as the keys from Store.activeSecondsByDay.
const dayKey = (year, month, day) =>
  `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;

/// The range a drag covers, in either direction, between two minute starts. `to`
/// is exclusive, so it runs through the end of the later minute.
const rangeBetween = (a, b) => ({ from: Math.min(a, b), to: Math.max(a, b) + 60 });

/// Local midnight. Out-of-range values roll over, and DST days stay correct,
/// which adding 86400 to an epoch would not.
const epochOf = (year, month, day) => new Date(year, month, day).getTime() / 1000;
