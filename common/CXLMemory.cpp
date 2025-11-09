//
// Created by Yibo Huang on 8/8/24.
//

#include "common/CXLMemory.h"

namespace star
{

CXLMemory cxl_memory;

// Initialize static members for file system synchronization
int CXLMemory::sync_fd = -1;
std::string CXLMemory::sync_file_path = "";
bool CXLMemory::use_file_sync = false;

}
