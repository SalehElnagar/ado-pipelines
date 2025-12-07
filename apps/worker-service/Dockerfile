# syntax=docker/dockerfile:1

ARG NODE_VERSION=18

FROM node:${NODE_VERSION}-alpine AS base
WORKDIR /app
COPY package*.json ./

FROM base AS deps
RUN npm ci

FROM deps AS test
COPY src ./src
RUN npm test

FROM deps AS runtime
COPY src ./src
ENV NODE_ENV=production
CMD ["npm", "start"]
