#define HAS_ORTHANC_EXCEPTION 1

#include <OrthancCPlugin.h>
#include <json/value.h>
#include <json/reader.h>
#include <json/writer.h>
#include <curl/curl.h>
#include <fstream>
#include <string>
#include <sstream>
#include <cctype>
#include <chrono>
#include <thread>
#include <mutex>
#include <set>
#include <regex>
#include <unistd.h>

const std::regex EMAIL_REGEX(R"(([\w\.-]+@[\w\.-]+\.\w+))");
const std::regex PASSWORD_REGEX(R"(pw\s*=\s*([^\s]+))");
std::string GetOrthancUrl() {
    const char* envUrl = std::getenv("ORTHANC_URL");
    if (!envUrl) {
        throw std::runtime_error("Environment-variable ORTHANC_URL not set!");
    }
    return std::string(envUrl);
}
const std::string ORTHANC_URL = GetOrthancUrl();

OrthancPluginContext* globalContext = NULL;
std::set<std::string> processedStudies;
std::mutex mutex;

// libcurl callback
static size_t WriteCallback(void* contents, size_t size, size_t nmemb, void* userp) {
    ((std::string*)userp)->append((char*)contents, size * nmemb);
    return size * nmemb;
}

// HTTP functions
std::string httpGet(const std::string& url) {
    CURL* curl = curl_easy_init();
    std::string response;
    if (curl) {
        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
        curl_easy_perform(curl);
        curl_easy_cleanup(curl);
    }
    return response;
}

std::string httpPost(const std::string& url, const std::string& data, const std::string& contentType, bool acceptDicom = false) {
    CURL* curl = curl_easy_init();
    std::string response;
    if (curl) {
        struct curl_slist* headers = nullptr;
        headers = curl_slist_append(headers, ("Content-Type: " + contentType).c_str());
        if (acceptDicom) headers = curl_slist_append(headers, "Accept: application/dicom");
        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, data.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, data.size());
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
        curl_easy_perform(curl);
        curl_slist_free_all(headers);
        curl_easy_cleanup(curl);
    }
    return response;
}

void httpDelete(const std::string& url) {
    CURL* curl = curl_easy_init();
    if (curl) {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "DELETE");
        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_perform(curl);
        curl_easy_cleanup(curl);
    }
}

std::string extractId(const std::string& json) {
    std::regex re("\"ID\"\\s*:\\s*\"([^\"]+)\"");
    std::smatch match;
    return std::regex_search(json, match, re) ? match[1].str() : "";
}

static std::string Sanitize(const std::string& input) {
    std::string result = input;
    for (size_t i = 0; i < result.length(); ++i) {
        char& c = result[i];
        if (c == ' ' || c == '^') c = '_';
        else if (!isalnum(c) && c != '_' && c != '-' && c != '.') c = '-';
    }
    return result;
}

//  cleanup StudyDescription
bool CleanStudyDescriptionOnly(const std::string& studyId, const std::string& cleanDescription, std::string& newStudyIdOut) {
    Json::Value payload;
    
    //  remove Email/Password
    payload["Replace"]["StudyDescription"] = cleanDescription;
    
    //  cleanup StudyID
    payload["Replace"]["StudyID"] = cleanDescription.substr(0, 16);
    payload["Force"] = true;

    Json::StreamWriterBuilder writer;
    std::string modifyResponse = httpPost(ORTHANC_URL + "/studies/" + studyId + "/modify", 
                                         Json::writeString(writer, payload), "application/json");
    
    newStudyIdOut = extractId(modifyResponse);
    return !newStudyIdOut.empty();
}

bool UpdateMappingFileAtomic(const std::string& filename, const std::string& email) {
    std::string tempMappingFile = "/exports/.mapping_temp.json";
    std::string finalMappingFile = "/exports/mapping.json";
    
    std::vector<std::string> existingEntries;
    std::ifstream existingFile(finalMappingFile);
    if (existingFile.is_open()) {
        std::string line;
        while (std::getline(existingFile, line)) {
            if (!line.empty()) {
                existingEntries.push_back(line);
            }
        }
        existingFile.close();
    }
    
    std::ofstream tempMapping(tempMappingFile);
    if (!tempMapping.is_open()) {
        OrthancPluginLogError(globalContext, "Failed to create temp mapping file");
        return false;
    }
    
    // write old entries
    for (const auto& entry : existingEntries) {
        tempMapping << entry << "\n";
    }
    
    // add new entries
    tempMapping << "{\"file\": \"" << filename << "\", \"email\": \"" << email << "\"}\n";
    tempMapping.close();
    
    if (rename(tempMappingFile.c_str(), finalMappingFile.c_str()) != 0) {
        OrthancPluginLogError(globalContext, "Failed to update mapping file atomically");
        std::remove(tempMappingFile.c_str());
        return false;
    }
    
    return true;
}

// Main export function with Race-Condition-Fixes
void ExportStudy(const std::string& studyId) {
    // Get study info
    std::string studyResponse = httpGet(ORTHANC_URL + "/studies/" + studyId);
    if (studyResponse.empty()) return;

    Json::Value studyInfo;
    Json::CharReaderBuilder reader;
    std::string errs;
    std::istringstream s(studyResponse);
    if (!Json::parseFromStream(reader, s, &studyInfo, &errs)) return;

    std::string description = studyInfo["MainDicomTags"].get("StudyDescription", "").asString();
    
    // Get ORIGINAL patient info
    std::string originalPatientId = "Unknown";
    if (studyInfo.isMember("ParentPatient")) {
        std::string patientResponse = httpGet(ORTHANC_URL + "/patients/" + studyInfo["ParentPatient"].asString());
        if (!patientResponse.empty()) {
            Json::Value patientInfo;
            std::istringstream ps(patientResponse);
            if (Json::parseFromStream(reader, ps, &patientInfo, &errs)) {
                originalPatientId = patientInfo["MainDicomTags"].get("PatientID", "Unknown").asString();
            }
        }
    }

    std::string studyDate = studyInfo["MainDicomTags"].get("StudyDate", "nodate").asString();

    // Extract email and password
    std::smatch pwMatch, emailMatch;
    std::string password = std::regex_search(description, pwMatch, PASSWORD_REGEX) ? pwMatch.str(1) : "default123";
    std::string email = std::regex_search(description, emailMatch, EMAIL_REGEX) ? emailMatch.str(1) : "";
    
    if (email.empty()) {
        OrthancPluginLogError(globalContext, "No email found in StudyDescription");
        return;
    }

    // Clean description ERST (für Filename-Berechnung)
    std::string cleanedDescription = std::regex_replace(description, EMAIL_REGEX, "");
    cleanedDescription = std::regex_replace(cleanedDescription, PASSWORD_REGEX, "");
    cleanedDescription.erase(0, cleanedDescription.find_first_not_of(" \t"));
    cleanedDescription.erase(cleanedDescription.find_last_not_of(" \t") + 1);

    std::string filenameBase = Sanitize(originalPatientId) + "_" + Sanitize(studyDate) + "_" + Sanitize(cleanedDescription);
    std::string tempZipPath = "/exports/." + filenameBase + "_temp.zip";
    std::string finalZipPath = "/exports/" + filenameBase + ".zip";
    std::string finalFilename = filenameBase + ".zip";

    std::string newStudyId;
    if (!CleanStudyDescriptionOnly(studyId, cleanedDescription, newStudyId)) {
        OrthancPluginLogError(globalContext, "Study description cleaning failed");
        return;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(1000));
    
    // Download ZIP from cleaned Study
    std::string zipData = httpGet(ORTHANC_URL + "/studies/" + newStudyId + "/archive");
    
    // Fallback to original if needed
    if (zipData.empty()) {
        OrthancPluginLogWarning(globalContext, "Cleaned study ZIP failed, using original");
        zipData = httpGet(ORTHANC_URL + "/studies/" + studyId + "/archive");
    }
    
    if (zipData.empty()) {
        OrthancPluginLogError(globalContext, "Failed to create ZIP archive");
        return;
    }

    std::ofstream tempFile(tempZipPath, std::ios::binary);
    if (!tempFile) {
        OrthancPluginLogError(globalContext, "Failed to create temp ZIP file");
        return;
    }
    tempFile << zipData;
    tempFile.close();
    
    sync();

    // Create encrypted ZIP with ZipCrypto
    std::string compressCmd = "7z a -tzip -mem=ZipCrypto -p'" + password + "' \"" + finalZipPath + "\" \"" + tempZipPath + "\"";
    
    if (system(compressCmd.c_str()) != 0) {
        OrthancPluginLogError(globalContext, "Failed to create encrypted ZIP");
        std::remove(tempZipPath.c_str());
        return;
    }

    std::remove(tempZipPath.c_str());
    
    sync();
    
    // delete original study after new ZIP successfully created
    if (!newStudyId.empty()) {
        httpDelete(ORTHANC_URL + "/studies/" + studyId);
    }

    if (!UpdateMappingFileAtomic(finalFilename, email)) {
        OrthancPluginLogError(globalContext, "Failed to update mapping file");
        return;
    }

    sync();
    
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    std::string payload = "studyId=" + studyId + "&file=" + finalFilename + "&email=" + email;
    
    OrthancPluginLogInfo(globalContext, ("Calling QueuePlugin with payload: " + payload).c_str());
    
    std::string queueUrl = ORTHANC_URL + "/send";
    std::string curlCmd = "curl -X POST "
                         "-H \"Content-Type: application/x-www-form-urlencoded\" "
                         "-d \"" + payload + "\" "
                         "\"" + queueUrl + "\" "
                         "--max-time 30 --retry 3 --retry-delay 1 -v";
    
    OrthancPluginLogInfo(globalContext, ("Executing curl command: " + curlCmd).c_str());
    
    int curlResult = system(curlCmd.c_str());
    if (curlResult != 0) {
        OrthancPluginLogError(globalContext, ("QueuePlugin call failed with code: " + std::to_string(curlResult)).c_str());
        return;
    } else {
        OrthancPluginLogInfo(globalContext, "QueuePlugin call completed successfully");
    }

    OrthancPluginLogInfo(globalContext, ("Export completed successfully: " + finalFilename + " for " + email).c_str());
}

// Callback
OrthancPluginErrorCode OnChangeCallback(OrthancPluginChangeType changeType,
                                        OrthancPluginResourceType resourceType,
                                        const char* resourceId) {
    if (changeType == OrthancPluginChangeType_StableStudy && resourceType == OrthancPluginResourceType_Study) {
        std::string studyId(resourceId);
        
        // Prevent loops
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (processedStudies.find(studyId) != processedStudies.end()) return OrthancPluginErrorCode_Success;
            processedStudies.insert(studyId);
        }
        
        // Check for email in description
        std::string studyResponse = httpGet(ORTHANC_URL + "/studies/" + studyId);
        if (studyResponse.empty()) return OrthancPluginErrorCode_Plugin;

        Json::Value studyInfo;
        Json::CharReaderBuilder reader;
        std::string errs;
        std::istringstream s(studyResponse);
        if (!Json::parseFromStream(reader, s, &studyInfo, &errs)) return OrthancPluginErrorCode_Plugin;

        if (!studyInfo.get("IsStable", false).asBool()) return OrthancPluginErrorCode_Success;

        std::string description = studyInfo["MainDicomTags"].get("StudyDescription", "").asString();
        std::smatch match;
        if (!std::regex_search(description, match, EMAIL_REGEX)) return OrthancPluginErrorCode_Success;

        ExportStudy(studyId);
    }
    return OrthancPluginErrorCode_Success;
}

// Plugin initialization
extern "C" {
    ORTHANC_PLUGINS_API int32_t OrthancPluginInitialize(OrthancPluginContext* context) {
        globalContext = context;
        curl_global_init(CURL_GLOBAL_DEFAULT);
        
        system("mkdir -p /exports");
        
        OrthancPluginLogInfo(context, "ExportPlugin started - RACE-CONDITION-SAFE VERSION 2.1");
        OrthancPluginRegisterOnChangeCallback(context, OnChangeCallback);
        return 0;
    }

    ORTHANC_PLUGINS_API void OrthancPluginFinalize() {
        curl_global_cleanup();
        OrthancPluginLogInfo(globalContext, "ExportPlugin stopped");
    }

    ORTHANC_PLUGINS_API const char* OrthancPluginGetName() { return "ExportPlugin"; }
    ORTHANC_PLUGINS_API const char* OrthancPluginGetVersion() { return "2.1"; }
}