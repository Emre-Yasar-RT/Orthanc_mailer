#include <OrthancCPlugin.h>
#include <iostream>
#include <fstream>
#include <string>
#include <unordered_map>
#include <filesystem>
#include <chrono>
#include <thread>
#include <vector>
#include <json/json.h>
#include <cstdlib>
#include <set>
#include <sys/wait.h>

OrthancPluginContext* globalContext = NULL;
std::thread watcherThread;
bool runWatcher = true;

namespace fs = std::filesystem;

const std::string EXPORTS_DIR = "/exports";
const std::string MAILQUEUE_DIR = "/mailqueue";
const std::string FILE_EXT = ".zip";
const int CHECK_INTERVAL = 10; 
const std::string PROCESSED_MARK = ".uploaded";
const std::string PROCESSING_MARK = ".uploading";
const std::string MAPPING_FILE = EXPORTS_DIR + "/mapping.json";

std::string getLogsDir() {
    return "/logs/filesender";
}

std::string getLogFile() {
    return getLogsDir() + "/filesender.log";
}

void log_to_file(const std::string& message) {
    std::string logsDir = getLogsDir();
    std::string logFile = getLogFile();
    
    // Debug: Auch nach stderr für Docker-Logs
    std::cerr << "[DEBUG] " << message << std::endl;
    
    try {
        fs::create_directories(logsDir);
        
        std::ofstream logfile(logFile, std::ios::app);
        if (logfile.is_open()) {
            auto now = std::chrono::system_clock::now();
            auto time_t = std::chrono::system_clock::to_time_t(now);
            auto tm = *std::localtime(&time_t);
            
            char timestamp[100];
            std::strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", &tm);
            
            logfile << "[" << timestamp << "] " << message << std::endl;
            logfile.close();
        } else {
            std::cerr << "[ERROR] Could not open log file: " << logFile << std::endl;
        }
    } catch (const std::exception& e) {
        std::cerr << "[ERROR] Log exception: " << e.what() << std::endl;
    }
}

void load_mapping(std::unordered_map<std::string, std::string>& mapping) {
    if (!fs::exists(MAPPING_FILE)) {
        return;
    }

    std::ifstream file(MAPPING_FILE);
    if (!file.is_open()) {
        log_to_file("Failed to open mapping.json.");
        return;
    }

    std::string line;
    while (std::getline(file, line)) {
        try {
            Json::CharReaderBuilder builder;
            std::string errs;
            Json::Value entry;

            std::istringstream ss(line);
            if (!Json::parseFromStream(builder, ss, &entry, &errs) || !entry.isObject()) {
                continue;
            }
            std::string zip_file = entry["file"].asString();
            std::string email = entry["email"].asString();
            if (!zip_file.empty() && !email.empty()) {
                mapping[zip_file] = email;
            }
        } catch (const std::exception& e) {
            continue;
        }
    }
}

bool UploadFileSync(const std::string& filepath, const std::string& email, const std::string& filename) {
    std::string username = std::getenv("FILESENDER_USERNAME") ? std::getenv("FILESENDER_USERNAME") : "";
    std::string apikey = std::getenv("FILESENDER_API_KEY") ? std::getenv("FILESENDER_API_KEY") : "";
    
    if (username.empty() || apikey.empty()) {
        log_to_file("ERROR: FILESENDER_USERNAME or FILESENDER_API_KEY not set");
        return false;
    }
    
    std::string logFile = "/tmp/upload_" + filename + ".log";
    std::string command = "timeout 300 python3 /filesender_cli/filesender.py \"" + filepath + 
                         "\" --recipients \"" + email + 
                         "\" -u \"" + username + 
                         "\" -a \"" + apikey + 
                         "\" > \"" + logFile + "\" 2>&1";
    
    log_to_file("Starting synchronous upload: " + filename + " to " + email);
    log_to_file("Upload command: " + command);
    
    int result = system(command.c_str());
    
    if (WIFEXITED(result)) {
        int exit_code = WEXITSTATUS(result);
        if (exit_code == 0) {
            log_to_file("Upload successful: " + filename);
            return true;
        } else if (exit_code == 124) {  // timeout exit code
            log_to_file("Upload timed out after 300 seconds: " + filename);
        } else {
            log_to_file("Upload failed with exit code " + std::to_string(exit_code) + ": " + filename);
        }
    } else if (WIFSIGNALED(result)) {
        int signal = WTERMSIG(result);
        log_to_file("Upload process killed by signal " + std::to_string(signal) + ": " + filename);
    } else {
        log_to_file("Upload process ended abnormally: " + filename);
    }
    
    std::ifstream errorLog(logFile);
    if (errorLog.is_open()) {
        std::string line;
        std::string errorDetails;
        int lineCount = 0;
        while (std::getline(errorLog, line) && lineCount < 20) {
            errorDetails += line + "\\n";
            lineCount++;
        }
        if (!errorDetails.empty()) {
            log_to_file("Upload error details for " + filename + ": " + errorDetails);
        }
        errorLog.close();
    }
    
    return false;
}

void cleanup_mapping() {
    std::unordered_map<std::string, std::string> mapping;
    load_mapping(mapping);

    std::vector<Json::Value> new_entries;

    for (const auto& [zip_file, email] : mapping) {
        fs::path uploaded_path = fs::path(MAILQUEUE_DIR) / (zip_file + PROCESSED_MARK);
        if (!fs::exists(uploaded_path)) {
            Json::Value obj;
            obj["file"] = zip_file;
            obj["email"] = email;
            new_entries.push_back(obj);
        }
    }

    std::string tempFile = MAPPING_FILE + ".tmp";
    std::ofstream file(tempFile);
    if (!file.is_open()) {
        log_to_file("Failed to open temp mapping.json to write.");
        return;
    }

    Json::StreamWriterBuilder writer;
    for (const auto& entry : new_entries) {
        file << Json::writeString(writer, entry) << std::endl;
    }
    file.close();
    
    if (rename(tempFile.c_str(), MAPPING_FILE.c_str()) != 0) {
        log_to_file("Failed to update mapping.json atomically");
        std::remove(tempFile.c_str());
    }
}

void FilesenderThread()
{
    OrthancPluginLogInfo(globalContext, "Filesender-Watcher started.");
    log_to_file("Filesender-Watcher started (Synchronous Uploads)");

    std::set<std::string> ignoredFiles; // files without e-mail should not be logged endlessy

    while (runWatcher) {
        try {
            std::unordered_map<std::string, std::string> mapping;
            load_mapping(mapping);

            if (!fs::exists(MAILQUEUE_DIR)) {
                log_to_file("Mailqueue directory does not exist: " + MAILQUEUE_DIR);
                std::this_thread::sleep_for(std::chrono::seconds(CHECK_INTERVAL));
                continue;
            }

            for (const auto& entry : fs::directory_iterator(MAILQUEUE_DIR)) {
                if (!entry.is_regular_file() || entry.path().extension() != FILE_EXT) {
                    continue;
                }

                std::string filename = entry.path().filename().string();
                fs::path full_path = fs::path(MAILQUEUE_DIR) / filename;

                if (fs::exists(full_path.string() + PROCESSED_MARK) || 
                    fs::exists(full_path.string() + PROCESSING_MARK)) {
                    continue;
                }

                auto recipient = mapping.find(filename);
                if (recipient == mapping.end()) {
                    if (ignoredFiles.find(filename) == ignoredFiles.end()) {
                        std::string msg = "No e-mail-adress known for: " + filename + " (will be ignored)";
                        log_to_file(msg);
                        ignoredFiles.insert(filename);
                    }
                    continue;
                }

                std::ofstream processingMarker(full_path.string() + PROCESSING_MARK);
                if (processingMarker.is_open()) {
                    processingMarker << "Processing started at " << std::time(nullptr) << std::endl;
                    processingMarker.close();
                } else {
                    log_to_file("Failed to create processing marker for: " + filename);
                    continue;
                }

                std::string msg = "File found: " + filename + " -> Recipient: " + recipient->second;
                log_to_file(msg);

                bool uploadSuccess = UploadFileSync(full_path.string(), recipient->second, filename);
                
                std::remove((full_path.string() + PROCESSING_MARK).c_str());
                
                if (uploadSuccess) {
                    std::ofstream marker(full_path.string() + PROCESSED_MARK);
                    if (marker.is_open()) {
                        marker << "Upload completed at " << std::time(nullptr) << std::endl;
                        marker.close();
                    }
                    
                    log_to_file("Upload completed successfully: " + filename);
                    
                    ignoredFiles.erase(filename);
                } else {
                    log_to_file("Upload failed, will retry next cycle: " + filename);
                }
            }

            cleanup_mapping();

        } catch (const std::exception& e) {
            std::string error_msg = "General error in FilesenderThread: " + std::string(e.what());
            log_to_file(error_msg);
        }

        std::this_thread::sleep_for(std::chrono::seconds(CHECK_INTERVAL));
    }

    OrthancPluginLogInfo(globalContext, "Filesender-Watcher ended.");
    log_to_file("Filesender-Watcher ended");
}

extern "C"
{
    ORTHANC_PLUGINS_API int32_t OrthancPluginInitialize(OrthancPluginContext* context)
    {
        globalContext = context;
        
        try {
            fs::create_directories(MAILQUEUE_DIR);
            fs::create_directories(getLogsDir());
        } catch (const std::exception& e) {
            OrthancPluginLogError(context, ("Failed to create directories: " + std::string(e.what())).c_str());
        }
        
        OrthancPluginLogInfo(context, "FilesenderPlugin started (Synchronous).");
        log_to_file("FilesenderPlugin initialized");
        
        watcherThread = std::thread(FilesenderThread);
        return 0;
    }

    ORTHANC_PLUGINS_API void OrthancPluginFinalize()
    {
        runWatcher = false;
        if (watcherThread.joinable())
            watcherThread.join();
        OrthancPluginLogInfo(globalContext, "FilesenderPlugin unloaded.");
        log_to_file("FilesenderPlugin finalized");
    }

    ORTHANC_PLUGINS_API const char* OrthancPluginGetName()
    {
        return "FilesenderPlugin";
    }

    ORTHANC_PLUGINS_API const char* OrthancPluginGetVersion()
    {
        return "2.2";
    }
}