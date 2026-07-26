package main

type authorizerRequest struct {
	Type               string `json:"type"`
	AuthorizationToken string `json:"authorizationToken"`
	MethodARN          string `json:"methodArn"`
}

type authorizerResponse struct {
	PrincipalID    string                 `json:"principalId"`
	PolicyDocument policyDocument         `json:"policyDocument"`
	Context        map[string]interface{} `json:"context"`
}

type policyDocument struct {
	Version   string            `json:"Version"`
	Statement []policyStatement `json:"Statement"`
}

type policyStatement struct {
	Action   string `json:"Action"`
	Effect   string `json:"Effect"`
	Resource string `json:"Resource"`
}

type authorizationConfig struct {
	Version           int                         `json:"version"`
	Users             map[string]userDefinition   `json:"users"`
	UserGroups        map[string]userGroup        `json:"userGroups"`
	AccessRightGroups map[string]accessRightGroup `json:"accessRightGroups"`
}

type userDefinition struct {
	Name       string            `json:"name"`
	Attributes map[string]string `json:"attributes"`
}

type userGroup struct {
	Description string         `json:"description,omitempty"`
	Users       []string       `json:"users,omitempty"`
	Match       conditionGroup `json:"match,omitempty"`
}

type accessRightGroup struct {
	Description string             `json:"description,omitempty"`
	Members     accessGroupMembers `json:"members"`
	Permissions []permission       `json:"permissions"`
}

type accessGroupMembers struct {
	Users      []string       `json:"users,omitempty"`
	UserGroups []string       `json:"userGroups,omitempty"`
	Match      conditionGroup `json:"match,omitempty"`
}

// All conditions must match. When Any is non-empty, at least one Any condition
// must also match. Empty All and Any means no attribute-based membership.
type conditionGroup struct {
	All []attributeCondition `json:"all,omitempty"`
	Any []attributeCondition `json:"any,omitempty"`
}

type attributeCondition struct {
	Attribute string   `json:"attribute"`
	Operator  string   `json:"operator"`
	Values    []string `json:"values"`
}

type permission struct {
	Actions   []string `json:"actions"`
	Resources []string `json:"resources"`
}
