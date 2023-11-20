import os
import re
import glob
import json
import click

from copy import deepcopy
from collections import defaultdict

from pprint import pprint


# default_variable_pattern = re.compile(r'\s*default\s*=\s*"(.+)".*')
default_variable_pattern = re.compile(r'default\s*=\s*["]*(?P<default_value>\[.*\]|[^"]+)', re.DOTALL)
data_remote_state_pattern = re.compile(r'data "terraform_remote_state".*?\n}', re.DOTALL)
data_foreach_pattern = re.compile(r'\s+for_each\s*=\s*(toset\()*(?P<iterator>[\w.]+)[)]*')
data_key_pattern = re.compile(r'\s+key\s*=\s*"env:/[${]*(?P<ws>[\w.]+)[}]*/(?P<backend_path>.+)"')
tfvars_path_pattern = re.compile(r'(?P<ws>[^/]+)\.env\.tfvars')
tf_path_pattern = ""
backend_file_name = "backend.tf"
backend_path_pattern = re.compile(rf".+/aws/(?P<resource>.+)/{re.escape(backend_file_name)}")
backend_key_pattern = re.compile(r'\s+key\s*=\s*"(?P<key>.+)"')


def get_workspace_dir() -> str:
    workspaces_path = os.path.dirname(__file__).split("/")
    workspaces_path[-1] = "aws"
    workspaces_path = "/".join(workspaces_path)
    return workspaces_path


def get_ws_by_vars_folder(component_path: str) -> list:
    """
    Creates a list of workspaces from list of *tfvars files in vars folder
    :param component_path: path to folder of the specific component
    :return: list
    """
    global tfvars_path_pattern
    ws = list()

    for path in glob.glob(f"{component_path}/vars/*"):
        m = tfvars_path_pattern.search(path)
        if m:
            ws.append(m.group('ws'))
    ws.sort()
    return ws


def get_pattern_search_values(pattern: str, file_paths: list, default_value="") -> dict:
    """
    Search for the given pattern in the content. Return empy string if it doesn't exist.
    :param pattern:       string. Enclose the part to fetch in brackets. For example: '\s*AWS_REGION\s*=\s*"(.+)"'
    :param default_value: the value to return if no pattern match
    :param file_paths:  list(string). A list of paths to files with a content to search within.
    :return:            dict. {<worksapce_name>: <variable value or default value if it's missing>}
    """
    re_pattern = re.compile(pattern)
    fetched_values = dict()
    for path in file_paths:
        fetched_value = default_value
        with open(path, "r") as file_r:
            if searched_m := re_pattern.search(file_r.read()):
                fetched_value = searched_m.group(1)
        fetched_values[os.path.basename(path)] = fetched_value
    return fetched_values


def collect_variable_from_vars(component_dir: str, variable_to_fetch: str, default_value=None) -> dict:
    global default_variable_pattern
    global tfvars_path_pattern
    values_per_ws = dict()
    return_dict = dict()

    try:
        if not default_value:
            variable_block = get_pattern_search_values(rf'\s*variable\s+"{variable_to_fetch}"\s+{{([^{{]+)}}',
                                                       [f"{component_dir}/variables.tf"])["variables.tf"]
            default_value = default_variable_pattern.search(variable_block).group(1)

        values_per_ws = get_pattern_search_values(rf'\s*{variable_to_fetch}\s*=\s*"(.+)"',
                                                  glob.glob(f"{component_dir}/vars/*tfvars"), default_value)
        for ws_tfvars_file, var_value in values_per_ws.items():
            if m := tfvars_path_pattern.search(ws_tfvars_file):
                return_dict[m.group('ws')] = json.loads(var_value) if '[' in var_value else [var_value]
    except Exception as e:
        print(f"[ERROR] Variable to fetch: {variable_to_fetch}; {component_dir}; {str(e)}")
    return return_dict


def generate_parent_ws(parent_ws_src: str, foreach_iterator: str, child_ws: list, child_folder: str) -> dict:
    """
    The function generates a list of workspaces from the source of the terraform_remote_state.
    :param parent_ws_src:    SRC from terraform_remote_state: key     = "env:/SRC/path"
    :param foreach_iterator: variable to use in 'for_each' loop
    :param child_ws:         a list of workspaces generated from tfvars files located in the vars folder of the current configuration.
    :param child_folder:     The path to the current configuration
    :return:        {
                        ws_src - The source data itself (SRC above)
                        ws     - The generated list of workspaces.
    """
    ws = dict(ws_src=parent_ws_src, ws={})
    if parent_ws_src == "terraform.workspace":
        ws["ws"] = {ws: [ws] for ws in child_ws}
    elif parent_ws_src.startswith("var."):
        ws["ws"] = collect_variable_from_vars(child_folder, parent_ws_src.split(".")[1])
    elif parent_ws_src == "each.value" and foreach_iterator.startswith("var."):
        ws["ws"] = collect_variable_from_vars(child_folder, foreach_iterator.split(".")[1])

    return ws


def collect_backends(root_dir: str) -> tuple:
    """
    Output:
        backends: dict. {backend_key: resource_folder}
        backend_ws: dict. {backend_key: workspaces_list}
    """
    global backend_path_pattern
    global backend_key_pattern
    backends = dict()
    backend_ws = dict()

    for path in glob.glob(f'{root_dir}/**/{backend_file_name}', recursive=True):
        with open(path, "r") as file_r:
            for line in file_r:
                m = backend_key_pattern.match(line)
                if m:
                    key = m.group('key')
                    backends[key] = backend_path_pattern.match(path).group('resource')
                    backend_ws[key] = get_ws_by_vars_folder(path.rstrip(backend_file_name))
                    break
    return backends, backend_ws


def write_json_to_file(file_name: str, dict_to_write: dict, spacelift_dependency: bool) -> None:
    if not spacelift_dependency:
        with open(file_name, "w") as write_file:
            json.dump(dict_to_write, write_file, indent=2)


def write_dependencies_to_file(file_name: str, dependencies_list: list, backend_ws: dict, backends_dict: dict) -> None:
    exchange_backends_dict = dict((v, k) for k, v in backends_dict.items())   # Creates a new dictionary by swapping the keys and values of an existing dictionary.

    with open(file_name, "w") as write_file:
        for node in dependencies_list:
            global_wsc = ':global' if 'global' in backend_ws[exchange_backends_dict[node]] else ''
            write_file.write(node + f"{global_wsc}\n")


def parse_remote_state_blocks(path: str) -> list:
    global data_remote_state_pattern
    global data_key_pattern
    global data_foreach_pattern
    output_list = list()
    with open(path, "r") as file_r:
        # Fetch all blocks of 'remote_state' from the current file.
        if remote_state_blocks := data_remote_state_pattern.findall(file_r.read()):
            for rs_block in remote_state_blocks:
                data_dict = dict(backend_path="", ws="", foreach_iterator="")
                if key := data_key_pattern.search(rs_block):
                    data_dict["ws"] = key.group("ws")
                    data_dict["ws"] = key.group("ws")
                    data_dict["backend_path"] = key.group("backend_path")
                if fp := data_foreach_pattern.search(rs_block):
                    data_dict["foreach_iterator"] = fp.group("iterator")
                output_list.append(data_dict)

    return output_list


def update_issues(dependencies_issues: dict, component_path: str, error_list: list) -> None:
    if not dependencies_issues.get(component_path):
        dependencies_issues[component_path] = list()
    dependencies_issues[component_path].append(error_list)


def collect_first_dependencies(backends_dict: dict, backend_ws: dict, root_dir: str, prj: str) -> dict:
    """
    Limitations of the current implementation of the search feature.:
        * Derive the configuration based solely on remote state data, without relying on data from a specific component.
    Input:  backends_dict: dict. {backend_key: component_folder, ...}
            backend_ws:  dict.
    Output: dict. { resource_folder = {"parent_ws" = {"ws_src": parent_backend_ws_name, "ws"=ws_list},
                                       "ws"= ws_list,
                                       "dependencies"={ dependent_resource_object, ...}}
    """
    dependencies = dict()
    dependencies_issues = dict()
    # data_pattern = re.compile(r'data\s*=\s*"(?P<data_type>.+)".+')

    ws_by_vars = dict()
    # Create a new dictionary by exchanging the keys and values of an existing dictionary.
    path_to_backends_dict = dict((v, k) for k, v in backends_dict.items())
    for path in glob.glob(f'{root_dir}/**/*.tf', recursive=True):
        component_dirname = os.path.dirname(path)
        short_component_path = tf_path_pattern.match(path).group('component_path')
        # Create a dictionary of workspaces per component
        if not ws_by_vars.get(component_dirname):
            ws_by_vars[component_dirname] = get_ws_by_vars_folder(component_dirname)
        # Initiate the root level of component dependencies
        if not dependencies.get(short_component_path):
            dependencies[short_component_path] = dict(parent_ws={},
                                                      ws=backend_ws.get(path_to_backends_dict[short_component_path]),
                                                      dependencies=dict())
        remote_states = parse_remote_state_blocks(path)
        for rs in remote_states:
            if not (parent_component_path := backends_dict.get(rs["backend_path"])):
                update_issues(dependencies_issues, short_component_path, [rs["backend_path"], "Bad key"])
                continue
            if parent_component_path == short_component_path:
                update_issues(dependencies_issues, parent_component_path, [parent_component_path,
                                                                           "is dependent on itself"])
                continue

            if not dependencies.get(parent_component_path):
                dependencies[parent_component_path] = dict(parent_ws=dict(), ws=backend_ws.get(rs["backend_path"]),
                                                           dependencies=dict())

            dependencies[parent_component_path]['dependencies'][short_component_path] = {
                "parent_ws": generate_parent_ws(rs["ws"], rs["foreach_iterator"], ws_by_vars[component_dirname],
                                                component_dirname),
                "ws": list(),
                "dependencies": dict()
            }
    write_json_to_file(f"dependencies_issues-{prj}.json", dependencies_issues, False)
    return dependencies


def improve_dependency(first_dependency: dict, current_level: dict, component: str) -> dict:
    if not current_level:
        current_level = first_dependency.get(component, {}).get('dependencies',{}).copy()
    else:
        for component in current_level.keys():
            current_level[component]['dependencies'] = improve_dependency(first_dependency,
                                                                         deepcopy(current_level[component]['dependencies']),
                                                                         component)
    return deepcopy(current_level)


def final_dependency_graph(dependency_graph:dict, input_dict: dict, spacelift_dependency: bool) -> dict:
    final_dependency_graph = dict()
    if spacelift_dependency:
        pass
        for paranet, dependencies in dependency_graph.items():
            parent_obj = input_dict.get(paranet, {})
            for parent_ws in parent_obj.get("ws", []):
                replaced_parant = paranet.replace("/", "-").replace(".", "-")
                node_name = f"{parent_ws}-{replaced_parant}"
                children_list = list()
                for child, child_obj in parent_obj.get("dependencies", {}).items():
                    replaced_child = child.replace("/", "-").replace(".", "-")
                    for children_ws, list_depens_on_parent_ws in child_obj.get("parent_ws", {}).get("ws", {}).items():
                        if parent_ws in list_depens_on_parent_ws:
                            children_list.append(f"{children_ws}-{replaced_child}")
                final_dependency_graph[node_name] = children_list
    else:
        final_dependency_graph = dependency_graph

    return final_dependency_graph


def create_dependency_graph(input_dict: dict, spacelift_dependency: bool) -> dict:
    """
    Create a dependency graph representation from the given input dictionary.
    """
    dependency_graph = {}

    def traverse_dependencies(component: str, dependencies: dict) -> None:
        """
        Helper function to traverse dependencies recursively and populate the dependency graph.
        """
        if component not in dependency_graph:
            dependency_graph[component] = set()

        for dependency in dependencies:
            dependency_graph[component].add(dependency)
            if dependencies[dependency]["dependencies"]:
                traverse_dependencies(dependency, dependencies[dependency]["dependencies"])

    # Traverse the input dictionary and populate the dependency graph
    for component, component_obj in input_dict.items():
        if component_obj["dependencies"]:
            traverse_dependencies(component, component_obj["dependencies"])

    # Update the data structure for node collection from set to list, and create the leaf nodes.
    leaf_nodes = set()
    start_nodes = dependency_graph.keys()

    for component in dependency_graph:
        nodes_list = list(dependency_graph[component])
        dependency_graph[component] = nodes_list
        for node in nodes_list:
            if node not in start_nodes:
                leaf_nodes.add(node)
    for node in leaf_nodes:
        dependency_graph[node] = []

    # Update the data structure for nodes missing in the created graph.
    for component in input_dict.keys():
        if not dependency_graph.get(component):
            # print(f"[INFO] Adding to graph the missing component '{component}'")
            dependency_graph[component] = []

    return final_dependency_graph(dependency_graph, input_dict, spacelift_dependency)


def topological_sort(graph: dict) -> list:
    """
    Perform topological sort on a directed acyclic graph (DAG).
    Args:
        graph (dict): The input graph represented as a dictionary with keys as nodes and values as lists of dependencies.
    Returns:
        list: A list of nodes sorted by their dependencies.
    """
    # Create a dictionary to store the count of incoming edges for each node
    incoming_edges = defaultdict(int)
    for node in graph:
        for dependency in graph[node]:
            incoming_edges[dependency] += 1

    # Create a queue to store nodes with no incoming edges
    queue = []
    for node in graph:
        if incoming_edges[node] == 0:
            queue.append(node)

    # Perform topological sort
    sorted_nodes = []
    while queue:
        node = queue.pop(0)
        sorted_nodes.append(node)

        # Decrement incoming edge count for all dependencies of the current node
        for dependency in graph[node]:
            incoming_edges[dependency] -= 1

            # If a dependency now has no incoming edges, add it to the queue
            if incoming_edges[dependency] == 0:
                queue.append(dependency)

    result_dict = {node: incomings for node, incomings in incoming_edges.items() if incomings > 0}
    if result_dict:
        print(f"[ERROR]: in 'incoming_edges' remaned following nodes: {result_dict}")

    return sorted_nodes


@click.command()
@click.option("--path", help="The Path to the root terraform folder (with 'aws' if exist)")
@click.option("--spacelift", is_flag=True, show_default=True, default=False, help="Create dependency graph for Spacelift")
def main(spacelift, path):
    print(spacelift)
    global tf_path_pattern
    tf_path_pattern = re.compile(rf"{path}/(?P<component_path>.+)/.+\.tf")
    print(path)
    backends, backend_ws = collect_backends(path)
    prj = "-".join(path.split('/')[-2:])
    write_json_to_file(f"backends-{prj}.json", backends, spacelift)
    write_json_to_file(f"backend-ws-{prj}.json", backend_ws, spacelift)
    first_dependency = collect_first_dependencies(backends, backend_ws, path, prj)
    write_json_to_file(f"first_dependency-{prj}.json", first_dependency, spacelift)

    prev_iteration = first_dependency.copy()
    improve_depend = {}
    count = 1
    while improve_depend != prev_iteration:
        print(f"Iterration: {count}")
        improve_depend = deepcopy(prev_iteration)
        prev_iteration = improve_dependency(first_dependency, improve_depend, "")
        count += 1
    write_json_to_file(f"improved_dependency-{prj}.json", improve_depend, spacelift)

    # Create a file for the create_destroy.env script
    dependency_graph = create_dependency_graph(improve_depend, spacelift)
    file_name = f"dependency-graph.json" if spacelift else f"dependency-graph-{prj}.json"
    write_json_to_file(file_name, dependency_graph, False)

    if not spacelift:
        dependency_list = topological_sort(dependency_graph)
        write_dependencies_to_file(f"dependency-list-{prj}.json", dependency_list, backend_ws, backends)


if __name__ == "__main__":
    main()


