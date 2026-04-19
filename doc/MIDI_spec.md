# Web MIDI Communication Specification (9x9 Extended / Center-Aligned)

## 1. Core Principles
- **Tuning:** Just Intonation (JI)
- **Mapping:** MIDI Note Numbers represent absolute coordinate indices in a 9x9 grid.
- **Scalability:** The 5x5 UI acts as a viewport into the center of a virtual 9x9 grid.

## 2. Message Structure

### 2.1 Note On
- **Status:** `0x90` (Channel 1)
- **Data 1 (Note Number):** 9x9 Mapping Index (76 = Central Tonic).
- **Data 2 (Velocity):** 0–127 (Based on contact area or vertical touch position).

### 2.2 Note Off
- **Status:** `0x80` (Channel 1)
- **Data 1 (Note Number):** Matches the Note On number.
- **Data 2 (Velocity):** `0`

### 2.3 Control Change (CC)
| CC# | Parameter | Value (Data 2) | Formula / Description |
| :--- | :--- | :--- | :--- |
| **20** | Dimension Switch | 3, 4, 5 | Sets dimensionality of JI ratios. |
| **21** | Sound Preset | 0–127 | Switches synthesizer engines. |
| **22** | Root Key Change | 0–11 | Sets JI reference pitch (C=0, C#=1...). |
| **23** | Octave Change | **61–67** | **Step-based Offset: `Value - 64`** |
| **7** | Master Volume | 0–127 | Overall gain control. |

## 3. Note Number Mapping (9x9 Grid)

- **Formula:** `NoteNumber = 36 + (y * 9) + x`
- **Center (Tonic):** (4,4) = **Note 76**

### Coordinate to Note Number Mapping (5x5 Viewport)
| y \ x | 2 | 3 | 4 (Center Axis) | 5 | 6 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **6 (Top)** | 92 | 93 | 94 | 95 | 96 |
| **5** | 83 | 84 | 85 | 86 | 87 |
| **4 (Center)** | 74 | 75 | **76 (Root)** | 77 | 78 |
| **3** | 65 | 66 | 67 | 68 | 69 |
| **2 (Bottom)** | 56 | 57 | 58 | 59 | 60 |

---
## 4. Control Logic: CC#23 Octave Offset Mapping
The value sent for CC#23 follows a 1-to-1 step increment/decrement centered at 64.

| CC Value | Octave Offset |
| :--- | :--- |
| **67** | +3 |
| **66** | +2 |
| **65** | +1 |
| **64** | **±0 (Unity)** |
| **63** | -1 |
| **62** | -2 |
| **61** | -3 |