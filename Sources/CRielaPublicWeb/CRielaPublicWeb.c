#include "CRielaPublicWeb.h"
#include <curl/curl.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct riela_web_cancel { atomic_bool cancelled; };
riela_web_cancel *riela_web_cancel_create(void) {
  riela_web_cancel *value = calloc(1, sizeof(*value));
  if (value) atomic_init(&value->cancelled, 0);
  return value;
}
void riela_web_cancel_set(riela_web_cancel *value) { if (value) atomic_store(&value->cancelled, 1); }
void riela_web_cancel_free(riela_web_cancel *value) { free(value); }

static int prefix6(const unsigned char *ip, const char *text, unsigned bits) {
  unsigned char base[16]; if (inet_pton(AF_INET6, text, base) != 1) return 0;
  unsigned bytes = bits / 8, tail = bits % 8;
  return !memcmp(ip, base, bytes) && (!tail || ((ip[bytes] ^ base[bytes]) & (0xff << (8-tail))) == 0);
}
static int public4(const unsigned char *bytes) {
  uint32_t ip; memcpy(&ip, bytes, 4); ip = ntohl(ip);
  static const struct { uint32_t ip; unsigned bits; } blocked[] = {
    {0x00000000,8},{0x0a000000,8},{0x64400000,10},{0x7f000000,8},{0xa9fe0000,16},
    {0xac100000,12},{0xc0000000,24},{0xc0000200,24},{0xc0586300,24},{0xc0a80000,16},
    {0xc6120000,15},{0xc6336400,24},{0xcb007100,24},{0xe0000000,4},{0xf0000000,4}
  };
  if (ip == 0xc0000009 || ip == 0xc000000a) return 1;
  for (size_t i=0;i<sizeof(blocked)/sizeof(blocked[0]);i++) {
    uint32_t mask = 0xffffffffU << (32-blocked[i].bits);
    if ((ip & mask) == blocked[i].ip) return 0;
  }
  return 1;
}
int riela_web_public_ip(const char *ip) {
  unsigned char bytes[16];
  if (!ip) return 0;
  if (inet_pton(AF_INET, ip, bytes) == 1) return public4(bytes);
  if (inet_pton(AF_INET6, ip, bytes) != 1) return 0;
  if (prefix6(bytes, "::ffff:0:0", 96)) return public4(bytes+12);
  // Only globally allocated unicast; transition, protocol and documentation
  // prefixes cannot route a public-page request into a private IPv4 network.
  return prefix6(bytes,"2000::",3) && !prefix6(bytes,"2001::",23) &&
    !prefix6(bytes,"2001:db8::",32) && !prefix6(bytes,"2002::",16) && !prefix6(bytes,"3fff::",20);
}

static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); xmlInitParser(); }
typedef struct {
  riela_web_response response;
  size_t maximum;
  riela_web_cancel *cancel;
  char expected_ip[INET6_ADDRSTRLEN];
} transfer;
static int cancelled(transfer *value) { return value->cancel && atomic_load(&value->cancel->cancelled); }
static int append_bytes(void **buffer, size_t *length, const void *bytes, size_t count, size_t maximum) {
  if (count > maximum || *length > maximum-count) return 0;
  void *next = realloc(*buffer, *length+count+1); if (!next) return 0;
  memcpy((unsigned char *)next+*length, bytes, count); *length += count;
  ((unsigned char *)next)[*length]=0; *buffer=next; return 1;
}
static size_t body(char *bytes, size_t size, size_t count, void *context) {
  transfer *value=context;
  if (size && count > SIZE_MAX/size) return 0;
  size_t length=size*count;
  if (cancelled(value)) { value->response.error=5; return 0; }
  if (!append_bytes((void **)&value->response.body,&value->response.body_length,bytes,length,value->maximum)) {
    value->response.error=4; return 0;
  }
  return length;
}
static size_t header(char *bytes, size_t size, size_t count, void *context) {
  transfer *value=context;
  if (size && count > SIZE_MAX/size) return 0;
  size_t length=size*count;
  if (!append_bytes((void **)&value->response.headers,&value->response.headers_length,bytes,length,65536)) {
    value->response.error=4; return 0;
  }
  return length;
}
static int progress(void *context,curl_off_t a,curl_off_t b,curl_off_t c,curl_off_t d) {
  (void)a;(void)b;(void)c;(void)d; transfer *value=context;
  if (cancelled(value)) { value->response.error=5; return 1; } return 0;
}
static int normalized_ip(const char *text, unsigned char bytes[16]) {
  unsigned char v4[4];
  if (inet_pton(AF_INET,text,v4)==1) {
    memset(bytes,0,16);bytes[10]=bytes[11]=0xff;memcpy(bytes+12,v4,4);return 1;
  }
  return inet_pton(AF_INET6,text,bytes)==1;
}
static int equal_ip(const char *a,const char *b) {
  unsigned char aa[16],bb[16]; return normalized_ip(a,aa)&&normalized_ip(b,bb)&&!memcmp(aa,bb,16);
}
static curl_socket_t open_socket(void *context,curlsocktype purpose,struct curl_sockaddr *address) {
  transfer *value=context;(void)purpose;
  if (cancelled(value)) { value->response.error=5;return CURL_SOCKET_BAD; }
  char ip[INET6_ADDRSTRLEN];const void *raw=NULL;int port=0;
  if (address->family==AF_INET) {
    struct sockaddr_in *a=(struct sockaddr_in *)&address->addr;raw=&a->sin_addr;port=ntohs(a->sin_port);
  } else if (address->family==AF_INET6) {
    struct sockaddr_in6 *a=(struct sockaddr_in6 *)&address->addr;raw=&a->sin6_addr;port=ntohs(a->sin6_port);
  }
  if (!raw||!inet_ntop(address->family,raw,ip,sizeof(ip))||port!=443||!riela_web_public_ip(ip)||
      !equal_ip(ip,value->expected_ip)) { value->response.error=2; return CURL_SOCKET_BAD; }
  return socket(address->family,address->socktype,address->protocol);
}
static int prerequisite(void *context,char *remote,char *local,int remote_port,int local_port) {
  (void)local;(void)local_port;transfer *value=context;
  if (cancelled(value)) { value->response.error=5;return CURL_PREREQFUNC_ABORT; }
  if (remote_port!=443||!riela_web_public_ip(remote)||!equal_ip(remote,value->expected_ip)) {
    value->response.error=2;return CURL_PREREQFUNC_ABORT;
  }
  return CURL_PREREQFUNC_OK;
}
static long elapsed_ms(struct timespec start) {
  struct timespec end;clock_gettime(CLOCK_MONOTONIC,&end);
  return (long)((end.tv_sec-start.tv_sec)*1000+(end.tv_nsec-start.tv_nsec)/1000000);
}
// libc DNS may block beyond the HTTP timeout. Own a bounded, detached resolver
// task; the caller can leave promptly while the final owner reaps its result.
// At most eight unresolved calls can remain after cancellation/deadline.
typedef struct {
  pthread_mutex_t lock;
  pthread_cond_t changed;
  unsigned owners;
  int done, result;
  char *host;
  struct addrinfo *addresses;
} resolution;
static pthread_mutex_t resolver_lock=PTHREAD_MUTEX_INITIALIZER;
static unsigned active_resolvers=0;
static void release_resolution(resolution *value) {
  pthread_mutex_lock(&value->lock);
  int destroy=--value->owners==0;
  pthread_mutex_unlock(&value->lock);
  if (!destroy) return;
  if (value->addresses) freeaddrinfo(value->addresses);
  free(value->host);pthread_cond_destroy(&value->changed);pthread_mutex_destroy(&value->lock);free(value);
}
static void *resolve_worker(void *context) {
  resolution *value=context;
  struct addrinfo hints={0},*addresses=NULL;hints.ai_socktype=SOCK_STREAM;hints.ai_family=AF_UNSPEC;
  int result=getaddrinfo(value->host,"443",&hints,&addresses);
  pthread_mutex_lock(&value->lock);
  value->result=result;value->addresses=addresses;value->done=1;
  pthread_cond_signal(&value->changed);pthread_mutex_unlock(&value->lock);
  pthread_mutex_lock(&resolver_lock);active_resolvers--;pthread_mutex_unlock(&resolver_lock);
  release_resolution(value);return NULL;
}
static int resolve_public(transfer *transfer, const char *host, struct timespec start, long timeout_ms) {
  if (cancelled(transfer)) return 5;
  pthread_mutex_lock(&resolver_lock);
  if (active_resolvers>=8) { pthread_mutex_unlock(&resolver_lock);return 3; }
  active_resolvers++;pthread_mutex_unlock(&resolver_lock);
  resolution *value=calloc(1,sizeof(*value));
  if (!value) goto allocation_failed;
  value->host=strdup(host);
  if (!value->host) { free(value);goto allocation_failed; }
  if (pthread_mutex_init(&value->lock,NULL)) { free(value->host);free(value);goto allocation_failed; }
  if (pthread_cond_init(&value->changed,NULL)) {
    pthread_mutex_destroy(&value->lock);free(value->host);free(value);goto allocation_failed;
  }
  value->owners=2;
  pthread_t worker;
  if (pthread_create(&worker,NULL,resolve_worker,value)) {
    value->owners=1;release_resolution(value);goto allocation_failed;
  }
  pthread_detach(worker);
  int result=0;
  pthread_mutex_lock(&value->lock);
  while (!value->done) {
    if (cancelled(transfer)) { result=5;break; }
    long remaining=timeout_ms-elapsed_ms(start);
    if (remaining<=0) { result=6;break; }
    struct timespec wake;clock_gettime(CLOCK_REALTIME,&wake);
    wake.tv_nsec+=(remaining<50?remaining:50)*1000000;
    if (wake.tv_nsec>=1000000000) { wake.tv_sec++;wake.tv_nsec-=1000000000; }
    pthread_cond_timedwait(&value->changed,&value->lock,&wake);
  }
  if (!result && value->result) result=3;
  if (!result) {
    size_t count=0;
    for (struct addrinfo *a=value->addresses;a;a=a->ai_next) {
      char ip[INET6_ADDRSTRLEN];const void *raw=NULL;
      if (a->ai_family==AF_INET) raw=&((struct sockaddr_in *)a->ai_addr)->sin_addr;
      if (a->ai_family==AF_INET6) raw=&((struct sockaddr_in6 *)a->ai_addr)->sin6_addr;
      if (!raw||++count>128||!inet_ntop(a->ai_family,raw,ip,sizeof(ip))||!riela_web_public_ip(ip)) { result=2;break; }
      if (!transfer->expected_ip[0]) memcpy(transfer->expected_ip,ip,strlen(ip)+1);
    }
    if (!transfer->expected_ip[0]) result=2;
  }
  pthread_mutex_unlock(&value->lock);release_resolution(value);return result;
allocation_failed:
  pthread_mutex_lock(&resolver_lock);active_resolvers--;pthread_mutex_unlock(&resolver_lock);return 3;
}

riela_web_response riela_web_fetch(const char *url,const char *host,const char *conditional_headers,
    size_t max_body_bytes,long timeout_ms,riela_web_cancel *cancel) {
  pthread_once(&initialized,initialize);
  transfer value={0};value.maximum=max_body_bytes;value.cancel=cancel;
  value.response.error=1;
  if (!url||!host||!max_body_bytes||max_body_bytes>8000000||timeout_ms<1||timeout_ms>120000) return value.response;
  struct timespec start;clock_gettime(CLOCK_MONOTONIC,&start);
  int resolved=resolve_public(&value,host,start,timeout_ms);
  if (resolved) { value.response.error=resolved;return value.response; }
  if (cancelled(&value)) { value.response.error=5;return value.response; }
  timeout_ms-=elapsed_ms(start);
  if (timeout_ms<=0) { value.response.error=6;return value.response; }
  CURL *curl=curl_easy_init(); if (!curl) { value.response.error=3;return value.response; }
  struct curl_slist *resolves=NULL,*headers=NULL;
  char resolve[1024];
  if (strchr(value.expected_ip,':')) snprintf(resolve,sizeof(resolve),"%s:443:[%s]",host,value.expected_ip);
  else snprintf(resolve,sizeof(resolve),"%s:443:%s",host,value.expected_ip);
  unsigned char literal[16];
  if (!normalized_ip(host,literal)) {
    resolves=curl_slist_append(NULL,resolve);
    if (!resolves) { value.response.error=3;goto cleanup; }
  }
  // The caller allows conditional GET headers only; no auth/cookies can cross
  // this native public reader, including from environment or redirect policy.
  if (conditional_headers&&*conditional_headers) {
    char *copy=strdup(conditional_headers),*save=NULL;
    if (!copy) { value.response.error=3;goto cleanup; }
    for (char *line=strtok_r(copy,"\n",&save);line;line=strtok_r(NULL,"\n",&save)) {
      struct curl_slist *next=curl_slist_append(headers,line);
      if (!next) { free(copy);value.response.error=3;goto cleanup; }
      headers=next;
    }
    free(copy);
  }
  value.response.error=0;
  #define SET(option, argument) do { if (curl_easy_setopt(curl, option, argument)!=CURLE_OK) { value.response.error=1;goto cleanup; } } while (0)
  SET(CURLOPT_URL,url);
  SET(CURLOPT_PROTOCOLS_STR,"https");
  SET(CURLOPT_REDIR_PROTOCOLS_STR,"https");
  SET(CURLOPT_FOLLOWLOCATION,0L);
  SET(CURLOPT_PROXY,"");
  SET(CURLOPT_NOPROXY,"*");
  SET(CURLOPT_NETRC,(long)CURL_NETRC_IGNORED);
  SET(CURLOPT_HTTPAUTH,(long)CURLAUTH_NONE);
  SET(CURLOPT_HTTP_VERSION,(long)CURL_HTTP_VERSION_1_1);
  SET(CURLOPT_SSL_VERIFYPEER,1L);
  SET(CURLOPT_SSL_VERIFYHOST,2L);
  SET(CURLOPT_NOSIGNAL,1L);
  SET(CURLOPT_TIMEOUT_MS,timeout_ms);
  SET(CURLOPT_CONNECTTIMEOUT_MS,timeout_ms<10000?timeout_ms:10000);
  SET(CURLOPT_USERAGENT,"Riela-Public-Web/1");
  SET(CURLOPT_ACCEPT_ENCODING,"identity");
  SET(CURLOPT_RESOLVE,resolves);
  SET(CURLOPT_HTTPHEADER,headers);
  SET(CURLOPT_WRITEFUNCTION,body);
  SET(CURLOPT_WRITEDATA,&value);
  SET(CURLOPT_HEADERFUNCTION,header);
  SET(CURLOPT_HEADERDATA,&value);
  SET(CURLOPT_XFERINFOFUNCTION,progress);
  SET(CURLOPT_XFERINFODATA,&value);
  SET(CURLOPT_NOPROGRESS,0L);
  SET(CURLOPT_OPENSOCKETFUNCTION,open_socket);
  SET(CURLOPT_OPENSOCKETDATA,&value);
  SET(CURLOPT_PREREQFUNCTION,prerequisite);
  SET(CURLOPT_PREREQDATA,&value);
  CURLcode result=curl_easy_perform(curl);
  curl_easy_getinfo(curl,CURLINFO_RESPONSE_CODE,&value.response.status);
  if (result!=CURLE_OK&&!value.response.error) value.response.error=result==CURLE_OPERATION_TIMEDOUT?6:3;
cleanup:
  #undef SET
  curl_slist_free_all(resolves);curl_slist_free_all(headers);curl_easy_cleanup(curl);
  return value.response;
}
void riela_web_response_free(riela_web_response *response) {
  if (!response) return;free(response->body);free(response->headers);memset(response,0,sizeof(*response));
}
xmlDocPtr riela_web_parse_html(const char *bytes,int count) {
  pthread_once(&initialized,initialize);
  if (!bytes||count<1||count>8000000) return NULL;
  return htmlReadMemory(bytes,count,NULL,"UTF-8",HTML_PARSE_NONET|HTML_PARSE_RECOVER|HTML_PARSE_NOERROR|HTML_PARSE_NOWARNING);
}
xmlDocPtr riela_web_parse_xml(const char *bytes,int count) {
  pthread_once(&initialized,initialize);
  if (!bytes||count<1||count>8000000) return NULL;
  xmlDocPtr doc=xmlReadMemory(bytes,count,NULL,NULL,XML_PARSE_NONET|XML_PARSE_NOERROR|XML_PARSE_NOWARNING);
  if (doc&&(doc->intSubset||doc->extSubset)) { xmlFreeDoc(doc);return NULL; }
  return doc;
}
void riela_web_xml_string_free(xmlChar *value) { xmlFree(value); }
