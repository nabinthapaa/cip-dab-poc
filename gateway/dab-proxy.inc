# Shared proxy settings for the DAB upstream.
# Identity headers are SET here, never passed through: anything the caller
# sent under these names is replaced (empty value = header dropped).
proxy_set_header X-MS-CLIENT-PRINCIPAL      $cip_principal;
proxy_set_header X-MS-API-ROLE              "client_reader";
proxy_set_header Ocp-Apim-Subscription-Key  "";
proxy_set_header Authorization              "";
proxy_set_header Cookie                     "";
proxy_set_header Host                       $host;
proxy_set_header X-Forwarded-For            $proxy_add_x_forwarded_for;
proxy_http_version 1.1;
proxy_set_header Connection "";
proxy_read_timeout 20s;
proxy_hide_header Server;
proxy_pass http://dab;
