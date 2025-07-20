#include <OrthancCPlugin.h>
#include <iostream>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <map>
#include <sstream>
#include <iomanip>
#include <chrono>
#include <thread>

OrthancPluginContext* globalContext = NULL;

bool FileExists(const std::string& path) {
  struct stat buffer;
  return (stat(path.c_str(), &buffer) == 0);
}

bool CopyFileAtomic(const std::string& from, const std::string& to) {
  if (!FileExists(from)) {
    return false;
  }
  
  std::string tempTo = to + ".tmp";
  
  std::ifstream src(from, std::ios::binary);
  std::ofstream dst(tempTo, std::ios::binary);
  
  if (!src || !dst) {
    return false;
  }
  
  dst << src.rdbuf();
  
  if (src.bad() || dst.bad()) {
    dst.close();
    src.close();
    std::remove(tempTo.c_str());
    return false;
  }
  
  dst.close();
  src.close();
  
  struct stat srcStat, dstStat;
  if (stat(from.c_str(), &srcStat) != 0 || stat(tempTo.c_str(), &dstStat) != 0) {
    std::remove(tempTo.c_str());
    return false;
  }
  
  if (srcStat.st_size != dstStat.st_size) {
    std::remove(tempTo.c_str());
    return false;
  }
  
  if (rename(tempTo.c_str(), to.c_str()) != 0) {
    std::remove(tempTo.c_str());
    return false;
  }
  
  sync();
  
  return true;
}

std::map<std::string, std::string> ParseFormData(const std::string& body)
{
  std::map<std::string, std::string> result;
  std::istringstream ss(body);
  std::string pair;
  while (std::getline(ss, pair, '&'))
  {
    size_t pos = pair.find('=');
    if (pos != std::string::npos)
    {
      std::string key = pair.substr(0, pos);
      std::string value = pair.substr(pos + 1);
      result[key] = value;
    }
  }
  return result;
}

std::string URLDecode(const std::string& value)
{
  std::ostringstream result;
  for (size_t i = 0; i < value.length(); ++i)
  {
    if (value[i] == '%' && i + 2 < value.length())
    {
      std::istringstream iss(value.substr(i + 1, 2));
      int hex = 0;
      if (iss >> std::hex >> hex)
      {
        result << static_cast<char>(hex);
        i += 2;
      }
    }
    else if (value[i] == '+')
    {
      result << ' ';
    }
    else
    {
      result << value[i];
    }
  }
  return result.str();
}

OrthancPluginErrorCode OnSendRoute(OrthancPluginRestOutput* output,
                                   const char* url,
                                   const OrthancPluginHttpRequest* request)
{
  OrthancPluginLogInfo(globalContext, "=== QueuePlugin /send route called ===");
  OrthancPluginLogInfo(globalContext, ("Request method: " + std::to_string(request->method)).c_str());
  OrthancPluginLogInfo(globalContext, ("Request URL: " + std::string(url)).c_str());
  OrthancPluginLogInfo(globalContext, ("Request body size: " + std::to_string(request->bodySize)).c_str());

  if (request->method != OrthancPluginHttpMethod_Post) {
    OrthancPluginLogError(globalContext, "Only POST method supported");
    OrthancPluginSendHttpStatusCode(globalContext, output, 405);
    return OrthancPluginErrorCode_Success;
  }

  if (request->bodySize == 0) {
    OrthancPluginLogError(globalContext, "Empty POST body");
    OrthancPluginSendHttpStatusCode(globalContext, output, 400);
    return OrthancPluginErrorCode_Success;
  }

  // Parse POST-Body
  std::string body(reinterpret_cast<const char*>(request->body), request->bodySize);
  
  OrthancPluginLogInfo(globalContext, ("Raw POST body: '" + body + "'").c_str());
  
  std::map<std::string, std::string> params = ParseFormData(body);

  OrthancPluginLogInfo(globalContext, ("Parsed parameters count: " + std::to_string(params.size())).c_str());
  for (const auto& param : params) {
    OrthancPluginLogInfo(globalContext, ("  " + param.first + " = '" + param.second + "'").c_str());
  }

  if (params.find("file") == params.end()) {
    OrthancPluginLogError(globalContext, "POST parameter 'file' not found in parsed parameters");
    
    std::string available_params = "Available parameters: ";
    for (const auto& param : params) {
      available_params += param.first + ", ";
    }
    OrthancPluginLogError(globalContext, available_params.c_str());
    
    OrthancPluginSendHttpStatusCode(globalContext, output, 400);
    return OrthancPluginErrorCode_Success;
  }

  std::string file = URLDecode(params["file"]);
  
  if (file.empty() || file.find("..") != std::string::npos) {
    OrthancPluginLogError(globalContext, "Invalid filename");
    OrthancPluginSendHttpStatusCode(globalContext, output, 400);
    return OrthancPluginErrorCode_Success;
  }

  std::string source = "/exports/" + file;
  std::string dest   = "/mailqueue/" + file;

  OrthancPluginLogInfo(globalContext, ("Attempting to move: " + source + " -> " + dest).c_str());

  std::this_thread::sleep_for(std::chrono::milliseconds(100));

  if (!FileExists(source)) {
    std::string error = "File not found: " + source;
    OrthancPluginLogError(globalContext, error.c_str());
    OrthancPluginSendHttpStatusCode(globalContext, output, 404);
    return OrthancPluginErrorCode_Success;
  }

  system("mkdir -p /mailqueue");

  if (!CopyFileAtomic(source, dest)) {
    std::string error = "Failed to copy file atomically: " + source + " -> " + dest;
    OrthancPluginLogError(globalContext, error.c_str());
    OrthancPluginSendHttpStatusCode(globalContext, output, 500);
    return OrthancPluginErrorCode_Success;
  }

  if (!FileExists(dest)) {
    std::string error = "Destination file verification failed: " + dest;
    OrthancPluginLogError(globalContext, error.c_str());
    OrthancPluginSendHttpStatusCode(globalContext, output, 500);
    return OrthancPluginErrorCode_Success;
  }

  if (unlink(source.c_str()) != 0) {
    std::string warning = "Failed to delete original file (but copy succeeded): " + source;
    OrthancPluginLogWarning(globalContext, warning.c_str());
  }

  std::string success = "File moved successfully: " + source + " -> " + dest;
  OrthancPluginLogInfo(globalContext, success.c_str());
  
  const char* successMsg = "OK";
  OrthancPluginAnswerBuffer(globalContext, output, successMsg, strlen(successMsg), "text/plain");
  
  return OrthancPluginErrorCode_Success;
}

extern "C"
{
  ORTHANC_PLUGINS_API int32_t OrthancPluginInitialize(OrthancPluginContext* context)
  {
    globalContext = context;
    
    system("mkdir -p /exports");
    system("mkdir -p /mailqueue");
    
    OrthancPluginRegisterRestCallback(context, "/send", OnSendRoute);
    OrthancPluginLogInfo(context, "QueuePlugin initialized with atomic operations.");
    return 0;
  }

  ORTHANC_PLUGINS_API void OrthancPluginFinalize()
  {
    OrthancPluginLogInfo(globalContext, "QueuePlugin finalized.");
  }

  ORTHANC_PLUGINS_API const char* OrthancPluginGetName() {
    return "QueuePlugin";
  }

  ORTHANC_PLUGINS_API const char* OrthancPluginGetVersion() {
    return "2.1";
  }
}