FROM nginx:alpine

COPY nginx.conf /etc/nginx/nginx.conf
COPY page1.html /usr/share/nginx/html/page1.html
COPY page2.html /usr/share/nginx/html/page2.html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
