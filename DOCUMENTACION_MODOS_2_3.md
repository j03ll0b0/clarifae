=== DOCUMENTACIÓN: MODOS 2 (DTLN) Y 3 (DEEPFILTERNET) ===

PLAN COMPLETO PARA INCLUIR MODOS 2 Y 3:

=== PASO A: TFLITE C LIBRARY (Modo 2) ===
Opción A1: Descargar de GitHub releases (tensorflow)
Opción A2: Descargar de tflite_c releases
Opción A3: Extraer de AAR / pip / apt (tflite-runtime no da .so host, pero buscamos referencia Android)
Opción A4: Si todo falla, descargar código fuente y compilar con CMake + NDK

=== PASO B: LIBDF (Modo 3) ===
Opción B1: Actualizar rust (rustup update stable) y usar cargo-ndk
Opción B2: Si cargo-ndk falla con rust viejo, instalar cargo-ndk manual (versión compatible con rust 1.75)
Opción B3: Si cargo-ndk no funciona, usar cargo build con target Android (target-dir) o compilar libDF como .a estática con cargo
Opción B4: Si todo falla, documentar referencia exacta y usar build con modos OFF como fallback, pero incluir instrucciones detalladas para el usuario

=== PASO C: DOCUMENTACIÓN ===
Crear archivo DOCUMENTACION_MODO_2_3.md con:
- Qué archivos faltan
- De dónde descargarlos
- Cómo compilarlos
- Qué variables de entorno usar (TFLITE_DIR, DF_DIR)
- Cómo verificar que funcionan (build.sh + log)
