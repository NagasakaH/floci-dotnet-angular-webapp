package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path"
	"sort"
	"strings"
)

type authorizationEngine struct {
	config authorizationConfig
}

func loadAuthorizationConfig(filePath string) (authorizationConfig, error) {
	content, err := os.ReadFile(filePath)
	if err != nil {
		return authorizationConfig{}, fmt.Errorf("read authorization config: %w", err)
	}
	var config authorizationConfig
	if err := json.Unmarshal(content, &config); err != nil {
		return authorizationConfig{}, fmt.Errorf("decode authorization config: %w", err)
	}
	if config.Version != 1 {
		return authorizationConfig{}, fmt.Errorf("unsupported authorization config version %d", config.Version)
	}
	if err := validateAuthorizationConfig(config); err != nil {
		return authorizationConfig{}, err
	}
	return config, nil
}

func validateAuthorizationConfig(config authorizationConfig) error {
	for groupName, group := range config.UserGroups {
		for _, userID := range group.Users {
			if _, exists := config.Users[userID]; !exists {
				return fmt.Errorf("userGroup %q references unknown user %q", groupName, userID)
			}
		}
	}
	for groupName, group := range config.AccessRightGroups {
		for _, userID := range group.Members.Users {
			if _, exists := config.Users[userID]; !exists {
				return fmt.Errorf("accessRightGroup %q references unknown user %q", groupName, userID)
			}
		}
		for _, userGroupName := range group.Members.UserGroups {
			if _, exists := config.UserGroups[userGroupName]; !exists {
				return fmt.Errorf(
					"accessRightGroup %q references unknown userGroup %q",
					groupName, userGroupName,
				)
			}
		}
		if len(group.Permissions) == 0 {
			return fmt.Errorf("accessRightGroup %q has no permissions", groupName)
		}
	}
	return nil
}

func (e authorizationEngine) identity(userID string) (userDefinition, bool) {
	user, exists := e.config.Users[userID]
	return user, exists
}

func (e authorizationEngine) authorize(userID, methodARN string) (bool, []string) {
	user, exists := e.identity(userID)
	if !exists {
		return false, nil
	}
	action, resource, ok := parseMethodARN(methodARN)
	if !ok {
		return false, nil
	}

	userGroups := e.resolveUserGroups(userID, user)
	accessGroups := make([]string, 0)
	allowed := false
	for name, group := range e.config.AccessRightGroups {
		if !isAccessGroupMember(userID, user, userGroups, group.Members) {
			continue
		}
		accessGroups = append(accessGroups, name)
		if matchesAnyPermission(action, resource, group.Permissions) {
			allowed = true
		}
	}
	sort.Strings(accessGroups)
	return allowed, accessGroups
}

func (e authorizationEngine) resolveUserGroups(userID string, user userDefinition) map[string]struct{} {
	result := make(map[string]struct{})
	for name, group := range e.config.UserGroups {
		if contains(group.Users, userID) || matchesConditions(user.Attributes, group.Match) {
			result[name] = struct{}{}
		}
	}
	return result
}

func isAccessGroupMember(
	userID string,
	user userDefinition,
	userGroups map[string]struct{},
	members accessGroupMembers,
) bool {
	if contains(members.Users, userID) || matchesConditions(user.Attributes, members.Match) {
		return true
	}
	for _, group := range members.UserGroups {
		if _, exists := userGroups[group]; exists {
			return true
		}
	}
	return false
}

func matchesConditions(attributes map[string]string, group conditionGroup) bool {
	if len(group.All) == 0 && len(group.Any) == 0 {
		return false
	}
	for _, condition := range group.All {
		if !matchesCondition(attributes, condition) {
			return false
		}
	}
	if len(group.Any) == 0 {
		return true
	}
	for _, condition := range group.Any {
		if matchesCondition(attributes, condition) {
			return true
		}
	}
	return false
}

func matchesCondition(attributes map[string]string, condition attributeCondition) bool {
	actual, exists := attributes[condition.Attribute]
	if !exists {
		return condition.Operator == "notExists"
	}
	switch condition.Operator {
	case "equals":
		return len(condition.Values) == 1 && actual == condition.Values[0]
	case "notEquals":
		return len(condition.Values) == 1 && actual != condition.Values[0]
	case "in":
		return contains(condition.Values, actual)
	case "contains":
		for _, value := range condition.Values {
			if strings.Contains(actual, value) {
				return true
			}
		}
		return false
	case "exists":
		return true
	case "notExists":
		return false
	default:
		return false
	}
}

func matchesAnyPermission(action, resource string, permissions []permission) bool {
	for _, permission := range permissions {
		if matchesPattern(permission.Actions, action) && matchesPattern(permission.Resources, resource) {
			return true
		}
	}
	return false
}

func matchesPattern(patterns []string, value string) bool {
	for _, pattern := range patterns {
		matched, err := path.Match(pattern, value)
		if err == nil && matched {
			return true
		}
	}
	return false
}

func parseMethodARN(methodARN string) (string, string, bool) {
	// arn:aws:execute-api:region:account:api-id/stage/METHOD/resource/path
	parts := strings.SplitN(methodARN, ":", 6)
	if len(parts) != 6 {
		return "", "", false
	}
	resourceParts := strings.Split(parts[5], "/")
	if len(resourceParts) < 3 {
		return "", "", false
	}
	action := strings.ToUpper(resourceParts[2])
	resource := "/"
	if len(resourceParts) > 3 {
		resource += strings.Join(resourceParts[3:], "/")
	}
	return action, resource, true
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
