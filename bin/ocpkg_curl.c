#include <curl/curl.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#define MAX_DOWNLOAD (64u * 1024u * 1024u)

struct download {
    FILE *file;
    size_t written;
    int exceeded;
};

static size_t write_archive(char *bytes, size_t size, size_t count, void *data)
{
    struct download *output = data;
    if (size != 0 && count > (MAX_DOWNLOAD - output->written) / size) {
        output->exceeded = 1;
        return 0;
    }
    size_t length = size * count;
    size_t written = fwrite(bytes, 1, length, output->file);
    output->written += written;
    return written;
}

CAMLprim value ocpkg_curl_download(value url, value filename)
{
    CAMLparam2(url, filename);
    CURLcode status = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (status != CURLE_OK)
        CAMLreturn(caml_copy_string(curl_easy_strerror(status)));

    CURL *curl = curl_easy_init();
    FILE *file = NULL;
    const char *error = "";
    char detail[CURL_ERROR_SIZE] = {0};
    struct download output = {0};
    if (curl == NULL) {
        error = "cannot initialize libcurl";
        goto done;
    }
    file = fopen(String_val(filename), "wb");
    if (file == NULL) {
        error = strerror(errno);
        goto done;
    }
    output.file = file;

#define SET_OPTION(option, value)                                      \
    do {                                                              \
        status = curl_easy_setopt(curl, option, value);                \
        if (status != CURLE_OK) goto handle_status;                           \
    } while (0)

    SET_OPTION(CURLOPT_ERRORBUFFER, detail);
    SET_OPTION(CURLOPT_URL, String_val(url));
    SET_OPTION(CURLOPT_PROTOCOLS_STR, "https");
    SET_OPTION(CURLOPT_REDIR_PROTOCOLS_STR, "https");
    SET_OPTION(CURLOPT_FOLLOWLOCATION, 1L);
    SET_OPTION(CURLOPT_MAXREDIRS, 5L);
    SET_OPTION(CURLOPT_FAILONERROR, 1L);
    SET_OPTION(CURLOPT_TIMEOUT, 30L);
    SET_OPTION(CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)MAX_DOWNLOAD);
    SET_OPTION(CURLOPT_WRITEFUNCTION, write_archive);
    SET_OPTION(CURLOPT_WRITEDATA, &output);
#undef SET_OPTION

    status = curl_easy_perform(curl);
handle_status:
    if (status != CURLE_OK) {
        if (output.exceeded || status == CURLE_FILESIZE_EXCEEDED)
            error = "archive exceeds the 64 MiB download limit";
        else
            error = detail[0] ? detail : curl_easy_strerror(status);
    }
done:
    if (file != NULL && fclose(file) != 0 && error[0] == '\0')
        error = "could not write archive";
    if (curl != NULL) curl_easy_cleanup(curl);
    curl_global_cleanup();
    CAMLreturn(caml_copy_string(error));
}
