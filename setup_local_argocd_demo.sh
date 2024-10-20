#!/bin/bash

# Définition des variables
MINIKUBE_PROFILE="argocd-demo"
KUBECTL_CONTEXT="argocd-demo"
GITLAB_URL=""
GITLAB_TOKEN=""
RUN_ALL=false
INSTALL_LOCAL_GITLAB=false

# Fonction pour vérifier si une commande existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Fonction pour demander confirmation
confirm() {
    if [ "$RUN_ALL" = true ]; then
        return 0
    fi
    read -p "$1 (y/n) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# Parsing des arguments CLI
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --gitlab-url) GITLAB_URL="$2"; shift ;;
        --gitlab-token) GITLAB_TOKEN="$2"; shift ;;
        --run-all) RUN_ALL=true ;;
        --install-local-gitlab) INSTALL_LOCAL_GITLAB=true ;;
        *) echo "Option inconnue: $1"; exit 1 ;;
    esac
    shift
done

# Étape 1: Installation des prérequis
install_prerequisites() {
    echo "Étape 1: Installation des prérequis"

    if ! command_exists docker; then
        if confirm "Docker n'est pas installé. Voulez-vous l'installer ?"; then
            echo "Installation de Docker..."
            sudo apt-get update
            sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
            sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
            sudo apt-get update
            sudo apt-get install -y docker-ce
            sudo usermod -aG docker $USER
            echo "Docker installé. Veuillez vous déconnecter et vous reconnecter pour que les changements prennent effet."
        fi
    fi

    if ! command_exists kubectl; then
        if confirm "kubectl n'est pas installé. Voulez-vous l'installer ?"; then
            echo "Installation de kubectl..."
            curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
            chmod +x kubectl
            sudo mv kubectl /usr/local/bin/
        fi
    fi

    if ! command_exists minikube; then
        if confirm "minikube n'est pas installé. Voulez-vous l'installer ?"; then
            echo "Installation de minikube..."
            curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
            sudo install minikube-linux-amd64 /usr/local/bin/minikube
        fi
    fi
}

# Étape 2: Mise en place de Minikube
setup_minikube() {
    echo "Étape 2: Mise en place de Minikube"

    # Vérifier si le profil existe déjà
    if ! minikube profile list | grep -q "$MINIKUBE_PROFILE"; then
        echo "Création d'un nouveau profil Minikube : $MINIKUBE_PROFILE"
        minikube start --profile=$MINIKUBE_PROFILE --driver=docker --cpus 2 --memory 2048 --disk-size 10g
    else
        echo "Le profil $MINIKUBE_PROFILE existe déjà. Démarrage du profil..."
        minikube start --profile=$MINIKUBE_PROFILE
    fi

    kubectl config use-context $KUBECTL_CONTEXT
    minikube addons enable ingress --profile=$MINIKUBE_PROFILE
    minikube addons enable storage-provisioner --profile=$MINIKUBE_PROFILE
}

# Étape 3: Installation d'ArgoCD
install_argocd() {
    echo "Étape 3: Installation d'ArgoCD"
    kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    echo "Attente du démarrage des pods ArgoCD..."
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

    kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
}

# Étape 4: Configuration de GitLab
configure_gitlab() {
    echo "Étape 4: Configuration de GitLab"
    if [ -z "$GITLAB_URL" ] || [ -z "$GITLAB_TOKEN" ]; then
        echo "L'URL GitLab ou le token n'ont pas été fournis. Veuillez les fournir en utilisant les options --gitlab-url et --gitlab-token."
        return 1
    fi

    # Création du secret pour GitLab dans ArgoCD
    kubectl create secret generic gitlab-secret \
        --from-literal=url=$GITLAB_URL \
        --from-literal=password=$GITLAB_TOKEN \
        -n argocd

    echo "Secret GitLab créé dans ArgoCD"
}

# Nouvelle étape : Installation de GitLab en local
install_local_gitlab() {
    echo "Installation de GitLab en local sur Minikube"

    # Installer Helm si ce n'est pas déjà fait
    if ! command_exists helm; then
        echo "Installation de Helm..."
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    # Ajouter le repo Helm de GitLab
    helm repo add gitlab https://charts.gitlab.io/
    helm repo update

    # Créer un namespace pour GitLab
    kubectl create namespace gitlab

    # Vérifier si l'IngressClass nginx existe déjà
#    if kubectl get ingressclass nginx &> /dev/null; then
#        echo "L'IngressClass nginx existe déjà. Suppression..."
#        kubectl delete ingressclass nginx
#    fi

    # Installer GitLab
    helm install gitlab gitlab/gitlab \
      --namespace gitlab \
      --set global.hosts.domain=$(minikube ip --profile=$MINIKUBE_PROFILE).nip.io \
      --set global.hosts.externalIP=$(minikube ip --profile=$MINIKUBE_PROFILE) \
      --set certmanager-issuer.email=votreemail@example.com \
      --set global.edition=ce \
      --set global.ingress.enabled=false \
      --set nginx-ingress.enabled=false \
      --set gitlab-webservice.service.type=NodePort \
      --set gitlab-webservice.service.nodePort=30080 \
      --set gitlab.gitlab-shell.service.type=NodePort \
      --set gitlab.gitlab-shell.service.nodePort=30022 \
      --set registry.service.type=NodePort \
      --set registry.service.nodePort=30005 \
      --timeout 600s

    # Attendre que tous les pods soient prêts
    kubectl wait --for=condition=Ready pods --all -n gitlab --timeout=600s


    # Attendre que le secret soit créé (avec un timeout de 5 minutes)
    echo "Attente de la création du secret GitLab..."
    for i in {1..30}; do
        if kubectl get secret gitlab-gitlab-initial-root-password -n gitlab &> /dev/null; then
            break
        fi
        echo "En attente du secret GitLab... (tentative $i/30)"
        sleep 10
    done

    # Obtenir le mot de passe root initial
    if kubectl get secret gitlab-gitlab-initial-root-password -n gitlab &> /dev/null; then
        GITLAB_ROOT_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath="{.data.password}" | base64 --decode)
        echo "GitLab est maintenant installé sur votre cluster Minikube!"
        echo "Vous pouvez y accéder à l'adresse: https://gitlab.$(minikube ip --profile=$MINIKUBE_PROFILE).nip.io"
        echo "Nom d'utilisateur: root"
        echo "Mot de passe: $GITLAB_ROOT_PASSWORD"

        # Mise à jour des variables GITLAB_URL et GITLAB_TOKEN
        GITLAB_URL="https://gitlab.$(minikube ip --profile=$MINIKUBE_PROFILE).nip.io"
        GITLAB_TOKEN=$GITLAB_ROOT_PASSWORD
    else
        echo "Erreur : Le secret GitLab n'a pas été créé dans le délai imparti."
        echo "Veuillez vérifier les logs de GitLab pour plus d'informations:"
        echo "kubectl logs -n gitlab -l app=webservice"
    fi

}

# Nouvelle fonction pour créer un tunnel WSL
create_wsl_tunnel() {
    echo "Création d'un tunnel WSL pour accéder à GitLab..."
    MINIKUBE_IP=$(minikube ip --profile=$MINIKUBE_PROFILE)

    # Vérifier si socat est installé
    if ! command -v socat &> /dev/null; then
        echo "socat n'est pas installé. Installation en cours..."
        sudo apt-get update && sudo apt-get install -y socat
    fi

    # Tuer les processus socat existants sur les ports utilisés
    sudo kill $(sudo lsof -t -i:30080) 2>/dev/null
    sudo kill $(sudo lsof -t -i:30022) 2>/dev/null
    sudo kill $(sudo lsof -t -i:30005) 2>/dev/null

    # Créer les tunnels
    sudo socat TCP-LISTEN:30080,fork TCP:$MINIKUBE_IP:30080 &
    sudo socat TCP-LISTEN:30022,fork TCP:$MINIKUBE_IP:30022 &
    sudo socat TCP-LISTEN:30005,fork TCP:$MINIKUBE_IP:30005 &

    echo "Tunnels créés. Vous pouvez maintenant accéder à GitLab depuis votre navigateur Windows à l'adresse:"
    echo "http://localhost:30080"
    echo "Le service SSH est disponible sur le port 30022"
    echo "Le registre Docker est disponible sur le port 30005"
}

# Étape 5: Configuration de la structure GitOps
setup_gitops_structure() {
    echo "Étape 5: Configuration de la structure GitOps"
    mkdir -p ~/gitops-repo
    cd ~/gitops-repo
    git init

    mkdir -p app-of-apps/{dev,staging,preprod,prod} applicationsets/{product-teams,shared-services} helm-charts/{home/weather,hub/lluvia} argocd-projects

    touch app-of-apps/dev/dev-app-of-apps.yaml
    touch applicationsets/product-teams/home-applicationset.yaml
    touch helm-charts/home/weather/{Chart.yaml,values.yaml}
    mkdir -p helm-charts/home/weather/templates
    touch helm-charts/home/weather/templates/{spring-boot-1.yaml,batch-1.yaml}
    touch argocd-projects/{home-project.yaml,hub-project.yaml}

    git add .
    git commit -m "Initial commit with GitOps structure"

    if [ ! -z "$GITLAB_URL" ]; then
        git remote add origin $GITLAB_URL
        git push -u origin master
    else
        echo "L'URL GitLab n'a pas été fournie. Veuillez pousser manuellement vers votre dépôt GitLab."
    fi
}

# Étape 6: Test du workflow
test_workflow() {
    echo "Étape 6: Test du workflow"
    ARGO_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    echo "Mot de passe admin ArgoCD: $ARGO_PASSWORD"

    ARGO_URL=$(minikube service argocd-server -n argocd --url --profile=$MINIKUBE_PROFILE)
    echo "URL d'ArgoCD: $ARGO_URL"

    echo "Configuration terminée !"
    echo "Veuillez suivre ces étapes manuelles :"
    echo "1. Connectez-vous à ArgoCD avec le nom d'utilisateur 'admin' et le mot de passe fourni ci-dessus"
    echo "2. Créez les applications ArgoCD basées sur la structure de votre dépôt"
}

# Menu principal
main() {
    echo "Configuration de l'environnement local ArgoCD"
    echo "----------------------------------------"

    if confirm "Voulez-vous installer les prérequis ?"; then
        install_prerequisites
    fi

    if confirm "Voulez-vous configurer Minikube ?"; then
        setup_minikube
    fi

    if confirm "Voulez-vous installer ArgoCD ?"; then
        install_argocd
    fi

    if [ "$INSTALL_LOCAL_GITLAB" = true ] || confirm "Voulez-vous installer GitLab en local ?"; then
        install_local_gitlab
        create_wsl_tunnel
    else
        if confirm "Voulez-vous configurer GitLab ?"; then
            configure_gitlab
        fi
    fi

    if confirm "Voulez-vous configurer la structure GitOps ?"; then
        setup_gitops_structure
    fi

    if confirm "Voulez-vous tester le workflow ?"; then
        test_workflow
    fi

    echo "Script terminé. Merci d'avoir utilisé ce configurateur !"
}

# Exécution du menu principal ou de toutes les étapes
if [ "$RUN_ALL" = true ]; then
    install_prerequisites
    setup_minikube
    install_argocd
    if [ "$INSTALL_LOCAL_GITLAB" = true ]; then
        install_local_gitlab
    else
        configure_gitlab
    fi
    setup_gitops_structure
    test_workflow
else
    main
fi
