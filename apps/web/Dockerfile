# --- build stage ---
FROM node:20-alpine AS build
WORKDIR /opt/app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# --- runtime ---
FROM node:20-alpine AS runtime
WORKDIR /opt/app
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000
COPY --from=build /opt/app/node_modules ./node_modules
COPY --from=build /opt/app/dist ./dist
COPY --from=build /opt/app/package.json ./package.json
EXPOSE 3000
CMD ["node", "./dist/server/entry.mjs"]
