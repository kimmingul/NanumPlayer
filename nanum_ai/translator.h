// Batched subtitle translation against an Ollama-compatible endpoint, with a
// persistent JSONL cache. Not thread safe: use from one thread.
#pragma once

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "consistency.h"

struct TranslatorConfig {
    std::string endpoint;           // "" disables translation
    std::string model;
    std::string source_language;    // human readable, e.g. "English"
    std::string target_language;    // human readable, e.g. "Korean"
    int timeout_ms = 90000;
    int context_lines = 3;
    std::string cache_path;         // "" disables persistence
    // Style and glossary, changeable from any thread while the translator
    // runs; null: the translator keeps its own (natural, empty).
    std::shared_ptr<nanum::Settings> settings;
};

class Translator {
public:
    explicit Translator(const TranslatorConfig &cfg);

    bool enabled() const { return !cfg_.endpoint.empty(); }

    // out[i] is the translation of src[i], or "" if it failed (failures are
    // never cached). Cached lines do not touch the network.
    void translate(const std::vector<std::string> &src,
                   std::vector<std::string> &out);

    size_t cache_size() const { return cache_.size(); }
    int requests() const { return requests_; }

    // True if the last translate() could not reach the endpoint (so trying
    // again later may help), as opposed to a model that returned unusable text.
    bool transport_failed() const { return transport_failed_; }

    // The language of the lines that are translated next (translator thread).
    void set_source_language(const std::string &s) { cfg_.source_language = s; }

    struct CompleteOptions {
        int num_ctx = 8192;
        int timeout_ms = 0;             // 0: the configured one
        std::string format_schema;      // JSON schema for Ollama's "format"; "": free text
        int max_tokens = 0;             // cap on the generated tokens, 0: none
        double repeat_penalty = 0;      // > 0: sent to the model (lists tend to loop)
        double temperature = 0.2;
    };

    // Free-form completion for the full pre-translation and the profile query. Not
    // cached. Returns false on a transport or server failure (error describes it).
    bool complete(const std::string &prompt, std::string &text, std::string &error,
                  const CompleteOptions &opt);

    // Call once a batch is final: its lines become context for the next one.
    void commit_context(const std::vector<std::string> &src);

    // Cancels a running request (from any thread) and makes every further
    // one fail immediately.
    void abort();

private:
    enum class Result { Ok, Transport, Malformed };

    static std::string make_key(const std::string &model, const std::string &target,
                                const std::string &style, const std::string &ghash,
                                const std::string &src);
    std::string key(const std::string &src) const;
    // names: put the glossary, the main characters and name hints into the prompt.
    Result request_lines(const std::vector<std::string> &src, std::vector<std::string> &out,
                         double temperature = 0.2, bool names = true);
    bool post(const std::string &body, std::string &response, int timeout_ms = 0);
    void remember(const std::string &src, const std::string &ko);

    TranslatorConfig cfg_;
    std::shared_ptr<nanum::Settings> settings_;
    // Snapshot of settings_ taken at the start of every translate() call.
    nanum::Settings::Snapshot cur_;
    std::string style_key_ = "natural";
    std::string style_instruction_;
    std::unordered_map<std::string, std::string> cache_;
    std::deque<std::string> recent_;    // previous source lines (context)
    bool send_think_ = true;            // dropped if the model rejects it
    int requests_ = 0;
    std::chrono::steady_clock::time_point down_until_{};
    bool first_request_ = true;         // gets a longer timeout (model load)
    bool transport_failed_ = false;
    std::atomic<bool> aborted_{false};
    std::atomic<void *> cur_req_{nullptr};
};
