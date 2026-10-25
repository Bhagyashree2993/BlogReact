# ---------- build stage ----------
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ARG VITE_API_URL=/api
ENV VITE_API_URL=${VITE_API_URL}
RUN npm run build

# ---------- runtime stage: unprivileged nginx on :8080 ----------
FROM nginxinc/nginx-unprivileged:1.27-alpine
# The nginx image runs envsubst on /etc/nginx/templates/*.template at startup,
# so BACKEND_HOST / BACKEND_PORT are injected from the Kubernetes Deployment.
ENV BACKEND_HOST=backend-service BACKEND_PORT=5000 \
    NGINX_ENVSUBST_FILTER="^BACKEND_"
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
