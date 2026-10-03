cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# main.cc         — точка входа + запуск backend через GUI sudo
# my_application.cc — GTK-приложение + shutdown-хук (POST /shutdown)
# main_hook.cc удалён — хук внутри my_application.cc
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

apply_standard_settings(${BINARY_NAME})

add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
