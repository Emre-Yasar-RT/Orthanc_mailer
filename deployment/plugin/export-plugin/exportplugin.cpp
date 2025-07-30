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
#include <iomanip>

const std::regex EMAIL_REGEX(R"(([\w\.-]+@[\w\.-]+\.\w+))");
const std::regex PASSWORD_REGEX(R"(pw\s*=\s*([^\s]+))");
std::string GetOrthancUrl() {
    const char* envUrl = std::getenv("ORTHANC_URL");
    if (!envUrl) {
        throw std::runtime_error("Umgebungsvariable ORTHANC_URL nicht gesetzt!");
    }
    return std::string(envUrl);
}
const std::string ORTHANC_URL = GetOrthancUrl();

OrthancPluginContext* globalContext = NULL;
std::set<std::string> activeStudies;
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

// Extract ALL emails from text dynamically
std::vector<std::string> extractAllEmails(const std::string& text) {
    std::vector<std::string> emails;
    std::sregex_iterator start(text.begin(), text.end(), EMAIL_REGEX);
    std::sregex_iterator end;
    
    for (std::sregex_iterator it = start; it != end; ++it) {
        std::string email = it->str(1);
        // avoid duplicate
        if (std::find(emails.begin(), emails.end(), email) == emails.end()) {
            emails.push_back(email);
        }
    }
    return emails;
}

//  Clean StudyDescription
bool CleanStudyDescriptionOnly(const std::string& studyId, const std::string& cleanDescription, std::string& newStudyIdOut) {
    Json::Value payload;
    payload["Replace"]["StudyDescription"] = cleanDescription;
    payload["Replace"]["StudyID"] = cleanDescription.substr(0, 16);
    payload["Force"] = true;

    Json::StreamWriterBuilder writer;
    std::string modifyResponse = httpPost(ORTHANC_URL + "/studies/" + studyId + "/modify", 
                                         Json::writeString(writer, payload), "application/json");
    
    newStudyIdOut = extractId(modifyResponse);
    return !newStudyIdOut.empty();
}
// Support multiple emails
bool UpdateMappingFileAtomic(const std::string& filename, const std::vector<std::string>& emails) {
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
    
    // Write existing entries
    for (const auto& entry : existingEntries) {
        tempMapping << entry << "\n";
    }
    
    // Create separate entry for each email
    for (const auto& email : emails) {
        tempMapping << "{\"file\": \"" << filename << "\", \"email\": \"" << email << "\"}\n";
    }
    tempMapping.close();
    
    if (rename(tempMappingFile.c_str(), finalMappingFile.c_str()) != 0) {
        OrthancPluginLogError(globalContext, "Failed to update mapping file atomically");
        std::remove(tempMappingFile.c_str());
        return false;
    }
    
    return true;
}

// Dynamic send function for multiple recipients
void sendToAllRecipients(const std::string& studyId, const std::string& finalFilename, const std::vector<std::string>& emails) {
    for (size_t i = 0; i < emails.size(); ++i) {
        const std::string& email = emails[i];
        
        std::string payload = "studyId=" + studyId + "&file=" + finalFilename + "&email=" + email;
        
        OrthancPluginLogInfo(globalContext, ("Calling QueuePlugin for recipient " + std::to_string(i+1) + "/" + std::to_string(emails.size()) + ": " + email).c_str());
        
        std::string queueUrl = ORTHANC_URL + "/send";
        std::string curlCmd = "curl -X POST "
                             "-H \"Content-Type: application/x-www-form-urlencoded\" "
                             "-d \"" + payload + "\" "
                             "\"" + queueUrl + "\" "
                             "--max-time 30 --retry 3 --retry-delay 1 -v";
        
        OrthancPluginLogInfo(globalContext, ("Executing curl command: " + curlCmd).c_str());
        
        int curlResult = system(curlCmd.c_str());
        if (curlResult != 0) {
            OrthancPluginLogError(globalContext, ("QueuePlugin call failed for " + email + " with code: " + std::to_string(curlResult)).c_str());
        } else {
            OrthancPluginLogInfo(globalContext, ("QueuePlugin call completed successfully for: " + email).c_str());
        }
        
        if (i < emails.size() - 1) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
    }
}

// Main export function with race condition fixes and multi-email support
void ExportStudy(const std::string& studyId) {
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (activeStudies.find(studyId) != activeStudies.end()) {
            OrthancPluginLogInfo(globalContext, ("Export already in progress for study: " + studyId).c_str());
            return;
        }
        activeStudies.insert(studyId);
    }
    
    // Cleanup guard for activeStudies
    struct ActiveStudyGuard {
        std::string studyId;
        ~ActiveStudyGuard() {
            std::lock_guard<std::mutex> lock(mutex);
            activeStudies.erase(studyId);
        }
    } guard{studyId};
    
    // Get study info
    std::string studyResponse = httpGet(ORTHANC_URL + "/studies/" + studyId);
    if (studyResponse.empty()) return;

    Json::Value studyInfo;
    Json::CharReaderBuilder reader;
    std::string errs;
    std::istringstream s(studyResponse);
    if (!Json::parseFromStream(reader, s, &studyInfo, &errs)) return;

    std::string description = studyInfo["MainDicomTags"].get("StudyDescription", "").asString();
    
    // Get original patient info
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

    // Extract all emails and password dynamically
    std::vector<std::string> emails = extractAllEmails(description);
    std::smatch pwMatch;
    std::string password = std::regex_search(description, pwMatch, PASSWORD_REGEX) ? pwMatch.str(1) : "default123";
    
    if (emails.empty()) {
        OrthancPluginLogError(globalContext, "No email found in StudyDescription");
        return;
    }

    OrthancPluginLogInfo(globalContext, ("Found " + std::to_string(emails.size()) + " email recipients").c_str());

    // Clean description first (for filename calculation)
    std::string cleanedDescription = std::regex_replace(description, EMAIL_REGEX, "");
    cleanedDescription = std::regex_replace(cleanedDescription, PASSWORD_REGEX, "");
    cleanedDescription.erase(0, cleanedDescription.find_first_not_of(" \t"));
    cleanedDescription.erase(cleanedDescription.find_last_not_of(" \t") + 1);

    // Add timestamp for unique filenames
    auto now = std::chrono::system_clock::now();
    auto time_t = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()) % 1000;
    
    std::stringstream timestampStr;
    timestampStr << std::put_time(std::localtime(&time_t), "%Y%m%d_%H%M%S");
    timestampStr << "_" << std::setfill('0') << std::setw(3) << ms.count();

    std::string filenameBase = Sanitize(originalPatientId) + "_" + Sanitize(studyDate) + "_" + Sanitize(cleanedDescription) + "_" + timestampStr.str();
    std::string tempZipPath = "/exports/." + filenameBase + "_temp.zip";
    std::string finalZipPath = "/exports/" + filenameBase + ".zip";
    std::string finalFilename = filenameBase + ".zip";

    std::string newStudyId;
    if (!CleanStudyDescriptionOnly(studyId, cleanedDescription, newStudyId)) {
        OrthancPluginLogError(globalContext, "Study description cleaning failed");
        return;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(1000));
    
    // Download ZIP from cleaned study
    std::string zipData = httpGet(ORTHANC_URL + "/studies/" + newStudyId + "/archive");
    
    // Fallback to original if necessary
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
    
    // Delete original study after successful ZIP creation
    if (!newStudyId.empty()) {
        httpDelete(ORTHANC_URL + "/studies/" + studyId);
    }

    // Update mapping for all emails
    if (!UpdateMappingFileAtomic(finalFilename, emails)) {
        OrthancPluginLogError(globalContext, "Failed to update mapping file");
        return;
    }

    sync();
    
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    // Send to all recipients dynamically
    sendToAllRecipients(studyId, finalFilename, emails);

    OrthancPluginLogInfo(globalContext, ("Export completed successfully: " + finalFilename + " for " + std::to_string(emails.size()) + " recipients").c_str());
}

// Callback for study processing
OrthancPluginErrorCode OnChangeCallback(OrthancPluginChangeType changeType,
                                        OrthancPluginResourceType resourceType,
                                        const char* resourceId) {
    if (changeType == OrthancPluginChangeType_StableStudy && resourceType == OrthancPluginResourceType_Study) {
        std::string studyId(resourceId);
        
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
        std::vector<std::string> emails = extractAllEmails(description);
        if (emails.empty()) return OrthancPluginErrorCode_Success;

        OrthancPluginLogInfo(globalContext, ("New study detected - processing for " + std::to_string(emails.size()) + " recipients").c_str());
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
        
        OrthancPluginLogInfo(context, "ExportPlugin started");
        OrthancPluginRegisterOnChangeCallback(context, OnChangeCallback);
        return 0;
    }

    ORTHANC_PLUGINS_API void OrthancPluginFinalize() {
        curl_global_cleanup();
        OrthancPluginLogInfo(globalContext, "ExportPlugin stopped");
    }

    ORTHANC_PLUGINS_API const char* OrthancPluginGetName() { return "ExportPlugin"; }
    ORTHANC_PLUGINS_API const char* OrthancPluginGetVersion() { return "2.8"; }
}