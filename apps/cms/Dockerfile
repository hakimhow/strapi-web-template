# Strapi v5 —— Node 22 推荐
# --- build ---
FROM node:22-alpine AS build
RUN apk add --no-cache build-base python3 vips-dev
WORKDIR /opt/app
COPY package*.json ./
RUN npm ci
COPY . .
RUN NODE_ENV=production npm run build

# --- runtime ---
FROM node:22-alpine AS runtime
RUN apk add --no-cache vips
WORKDIR /opt/app
ENV NODE_ENV=production HOST=0.0.0.0 PORT=1337
COPY --from=build /opt/app ./
EXPOSE 1337
CMD ["npm", "start"]
