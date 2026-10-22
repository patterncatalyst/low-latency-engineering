# Ch1 example: per-parcel vs batch-32 vs bimodal consumer (see ../README.md).
add_executable(latdist-consumer src/latdist.cpp)
target_link_libraries(latdist-consumer PRIVATE lowlat::line_consumer lowlat::warnings)
