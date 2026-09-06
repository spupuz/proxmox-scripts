## 2024-05-18 - Differentiating Skip vs Fast-Forward Empty States
**Learning:** The design system relies heavily on emojis for CLI scannability. Structural empty states (e.g., missing dependencies, missing configs) should use the fast-forward emoji (⏩️) to imply efficient, intentional processing. The skip track emoji (⏭️) must be exclusively reserved for items explicitly excluded by user configuration.
**Action:** Always use ⏩️ when gracefully bypassing logic due to environment constraints, and ⏭️ only for user-defined exclusions.
