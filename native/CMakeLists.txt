# Clarifae native audio pre-processing effect -> libclarifae.so
#
# Built per-ABI by ../build.sh using the Android NDK toolchain. RNNoise (the
# shipping engine) is compiled straight from third_party/rnnoise. DTLN and
# DeepFilterNet are optional, OFF by default.
cmake_minimum_required(VERSION 3.18)
project(clarifae C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

option(CLARIFAE_WITH_DTLN "Build the experimental DTLN (TFLite) backend" OFF)
option(CLARIFAE_WITH_DF   "Build the experimental DeepFilterNet (libdf) backend" OFF)

set(RNNOISE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/rnnoise"
    CACHE PATH "Path to the xiph/rnnoise checkout")

if(NOT EXISTS "${RNNOISE_DIR}/include/rnnoise.h")
  message(FATAL_ERROR
    "RNNoise not found at ${RNNOISE_DIR}. Run scripts/fetch_deps.sh first.")
endif()

# --- RNNoise sources (scalar/NEON C path), excluding tools/generators ---
file(GLOB RNN_SRCS "${RNNOISE_DIR}/src/*.c")
list(FILTER RNN_SRCS EXCLUDE REGEX "(dump_features|dump_rnnoise_tables|write_weights|rnnoise_data_little)")

if(NOT RNN_SRCS MATCHES "rnnoise_data")
  message(WARNING
    "rnnoise_data.c missing — run scripts/fetch_deps.sh (download_model.sh) to "
    "fetch the trained weights, or the link step will fail.")
endif()

set(CLARIFAE_SRCS
    effect.c
    config.c
    ringbuf.c
    resampler.c
    backend_rnnoise.c
    backend_dtln.c
    backend_deepfilternet.c)

add_library(clarifae SHARED ${CLARIFAE_SRCS} ${RNN_SRCS})

target_include_directories(clarifae PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${RNNOISE_DIR}/include
    ${RNNOISE_DIR}/src)

set_target_properties(clarifae PROPERTIES
    OUTPUT_NAME clarifae          # -> libclarifae.so
    C_VISIBILITY_PRESET hidden)

target_compile_options(clarifae PRIVATE
    -O2 -fPIC -ffunction-sections -fdata-sections
    -Wall -Wno-unused-parameter)

# RNNoise's scalar build needs no autotools config.h (its includes are guarded
# by HAVE_CONFIG_H, which we leave undefined).
target_compile_definitions(clarifae PRIVATE RNNOISE_BUILD)

target_link_options(clarifae PRIVATE -Wl,--gc-sections -Wl,--exclude-libs,ALL)

find_library(LOG_LIB log)
target_link_libraries(clarifae ${LOG_LIB} m)

# --- optional: DTLN via TensorFlow Lite C API ---
if(CLARIFAE_WITH_DTLN)
  set(TFLITE_DIR "" CACHE PATH "Dir with tensorflow/lite/c/c_api.h and libtensorflowlite_c.so")
  if(NOT TFLITE_DIR)
    message(FATAL_ERROR "CLARIFAE_WITH_DTLN=ON requires -DTFLITE_DIR=<tflite c sdk>")
  endif()
  target_compile_definitions(clarifae PRIVATE CLARIFAE_WITH_DTLN)
  target_include_directories(clarifae PRIVATE "${TFLITE_DIR}/include" "${TFLITE_DIR}")
  # Buscamos el .so específico del ABI activo (Android multi-arquitectura)
  # Bazel compila 3 .so (arm64-v8a, armeabi-v7a, x86_64) en tflite_ref/lib/$ABI/
  # Verificación explícita de archivo (más robusta que find_library con NO_DEFAULT_PATH)
  set(TFLITE_C_LIB "${TFLITE_DIR}/lib/${ANDROID_ABI}/libtensorflowlite_c.so")
  if(EXISTS "${TFLITE_C_LIB}")
    message(STATUS "TFLite .so encontrado (ABI=${ANDROID_ABI}): ${TFLITE_C_LIB}")
  else()
    set(TFLITE_C_LIB "${TFLITE_DIR}/lib/libtensorflowlite_c.so")
    if(EXISTS "${TFLITE_C_LIB}")
      message(STATUS "TFLite .so encontrado (plano): ${TFLITE_C_LIB}")
    else()
      set(TFLITE_C_LIB "${TFLITE_DIR}/libtensorflowlite_c.so")
      if(EXISTS "${TFLITE_C_LIB}")
        message(STATUS "TFLite .so encontrado (raíz): ${TFLITE_C_LIB}")
      else()
        message(FATAL_ERROR "libtensorflowlite_c no se encuentra para ABI=${ANDROID_ABI} (buscado: ${TFLITE_DIR}/lib/${ANDROID_ABI}/libtensorflowlite_c.so, luego ${TFLITE_DIR}/lib/libtensorflowlite_c.so, luego ${TFLITE_DIR}/libtensorflowlite_c.so)")
      endif()
    endif()
  endif()
  target_link_libraries(clarifae ${TFLITE_C_LIB})
  message(STATUS "Clarifae: DTLN backend enabled (${TFLITE_C_LIB})")
endif()

# --- optional: DeepFilterNet via libdf C FFI ---
if(CLARIFAE_WITH_DF)
  set(DF_DIR "" CACHE PATH "Dir containing libdf (the DeepFilterNet C-FFI library)")
  if(NOT DF_DIR)
    message(FATAL_ERROR "CLARIFAE_WITH_DF=ON requires -DDF_DIR=<libdf build dir>")
  endif()
  target_compile_definitions(clarifae PRIVATE CLARIFAE_WITH_DF)
  # Verificación explícita de archivo para libdf (DeepFilterNet C-FFI)
  set(DF_LIB "")
  set(DF_CANDIDATES ${DF_DIR}/libdf.so ${DF_DIR}/lib/libdf.so ${DF_DIR}/staging-${ANDROID_ABI}/libdf.so ${DF_DIR}/staging-arm64-v8a/libdf.so ${DF_DIR}/staging-armeabi-v7a/libdf.so ${DF_DIR}/target/ndk-${ANDROID_ABI}/release/libdf.so ${DF_DIR}/target/ndk-arm64-v8a/release/libdf.so ${DF_DIR}/target/ndk-armeabi-v7a/release/libdf.so)
  foreach(candidate ${DF_CANDIDATES})
    if(EXISTS "${candidate}")
      set(DF_LIB "${candidate}")
      message(STATUS "libdf encontrado: ${DF_LIB}")
      break()
    endif()
  endforeach()
  if(NOT DF_LIB)
    message(FATAL_ERROR "libdf no se encuentra para DF_DIR=${DF_DIR} (buscado en: ${DF_DIR}/libdf.so, lib/, staging-*/libdf.so, target/ndk-*/release/libdf.so)")
  endif()
  target_link_libraries(clarifae ${DF_LIB})
  message(STATUS "Clarifae: DeepFilterNet backend enabled (${DF_LIB})")
endif()
# Trigger: cambio bezel -> cmake (build CMake + NDK), trigger CI
# Trigger CI: run con -j2 aplicado (4ac90bd)
